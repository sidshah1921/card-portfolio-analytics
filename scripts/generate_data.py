"""Generate a synthetic credit card portfolio as raw CSV extracts.

The simulation is a month-by-month account-level state machine:

* every account carries a latent "stress" factor (AR(1)) that pushes spend up,
  payment rates down and - with a lag - delinquency risk up, so utilization is a
  genuine leading indicator of future delinquency;
* delinquency moves through cycles (0 = current, 1 = 30 DPD ... 6 = 180 DPD) with
  roll / stay / cure probabilities; 180 DPD triggers a charge-off;
* risk rises for subprime FICO (< 620) and Student cards, spend spikes in Q4;
* charged-off accounts can produce post-charge-off recovery payments.

After simulation a small share (~0.5-1%) of data-quality defects is injected into
the raw extracts (duplicate / restated statements, late-arriving loads, null FICO
refreshes, negative and duplicate payments, orphan payments). The dbt staging
layer is responsible for catching all of them.

All data is synthetic. No real customers, accounts or institutions are represented.
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd

PRODUCTS = np.array(["Cashback", "Travel", "Student", "Platinum"])
CASHBACK, TRAVEL, STUDENT, PLATINUM = range(4)

AGE_BANDS = np.array(["18-24", "25-34", "35-44", "45-54", "55-64", "65+"])
AGE_PROBS = [0.12, 0.22, 0.21, 0.18, 0.15, 0.12]
INCOME_BANDS = np.array(["<35k", "35k-60k", "60k-100k", "100k-150k", "150k+"])
CHANNELS = np.array(["Digital", "Direct Mail", "Branch", "Partner", "Referral"])
CHANNEL_PROBS = [0.45, 0.20, 0.15, 0.12, 0.08]

# Approximate state populations (millions) used as sampling weights.
STATE_POP = {
    "CA": 39.5, "TX": 29.1, "FL": 21.5, "NY": 20.2, "PA": 13.0, "IL": 12.8, "OH": 11.8,
    "GA": 10.7, "NC": 10.4, "MI": 10.1, "NJ": 9.3, "VA": 8.6, "WA": 7.7, "AZ": 7.2,
    "MA": 7.0, "TN": 6.9, "IN": 6.8, "MD": 6.2, "MO": 6.2, "WI": 5.9, "CO": 5.8,
    "MN": 5.7, "SC": 5.1, "AL": 5.0, "LA": 4.7, "KY": 4.5, "OR": 4.2, "OK": 4.0,
    "CT": 3.6, "UT": 3.3, "IA": 3.2, "NV": 3.1, "AR": 3.0, "MS": 3.0, "KS": 2.9,
    "NM": 2.1, "NE": 2.0, "ID": 1.8, "WV": 1.8, "HI": 1.5, "NH": 1.4, "ME": 1.4,
    "RI": 1.1, "MT": 1.1, "DE": 1.0, "SD": 0.9, "ND": 0.8, "AK": 0.7, "DC": 0.7,
    "VT": 0.6, "WY": 0.6,
}

# Product parameters, indexed by product code.
FICO_MEAN = np.array([695.0, 728.0, 648.0, 762.0])
FICO_SD = np.array([58.0, 45.0, 48.0, 35.0])
LIMIT_LO = np.array([1000.0, 3000.0, 300.0, 8000.0])
LIMIT_HI = np.array([15000.0, 25000.0, 2500.0, 40000.0])
APR = np.array([0.2399, 0.2199, 0.2499, 0.1999])
LATE_FEE = np.array([35.0, 35.0, 25.0, 40.0])
PRODUCT_RISK = np.array([0.0, -0.15, 0.45, -0.35])  # logit shift on current -> 30

# Spend seasonality by calendar month (Jan..Dec): Q4 holiday spike.
SPEND_SEASON = np.array([0.92, 0.88, 0.97, 0.98, 1.00, 1.00, 1.02, 1.00, 0.97, 1.05, 1.20, 1.35])
# Post-holiday payment stress (logit shift on current -> 30 by calendar month).
RISK_SEASON = np.array([0.20, 0.25, 0.05, 0.0, -0.05, 0.0, 0.0, 0.0, 0.0, -0.05, 0.0, 0.10])

# Delinquent-state transition probabilities, by cycle (index 1..5 used).
CURE = np.array([0, 0.42, 0.22, 0.12, 0.07, 0.04])
STAY = np.array([0, 0.22, 0.18, 0.14, 0.10, 0.06])
# remaining mass = roll forward one cycle


def sigmoid(x: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-x))


def month_start(base: np.datetime64, m: np.ndarray | int) -> np.ndarray:
    """First day of month `m` months after `base` (a datetime64[M])."""
    return (base + np.asarray(m).astype("timedelta64[M]")).astype("datetime64[D]")


def build_customers(rng: np.random.Generator, n_customers: int) -> dict[str, np.ndarray]:
    states = np.array(list(STATE_POP))
    pop = np.array(list(STATE_POP.values()))
    age = rng.choice(len(AGE_BANDS), n_customers, p=AGE_PROBS)

    income_base = np.array([0.16, 0.24, 0.31, 0.18, 0.11])
    income_young = np.array([0.55, 0.30, 0.12, 0.02, 0.01])
    u = rng.random(n_customers)
    cdf = np.where((age == 0)[:, None], income_young.cumsum(), income_base.cumsum())
    income = (u[:, None] > cdf).sum(axis=1)

    return {
        "state_idx": rng.choice(len(states), n_customers, p=pop / pop.sum()),
        "states": states,
        "age": age,
        "income": income,
        "channel": rng.choice(len(CHANNELS), n_customers, p=CHANNEL_PROBS),
    }


def choose_products(rng, age, income) -> np.ndarray:
    n = len(age)
    probs = np.tile([0.47, 0.28, 0.03, 0.22], (n, 1)).astype(float)
    probs[age == 0] = [0.30, 0.07, 0.60, 0.03]
    probs[age == 1] = [0.48, 0.28, 0.08, 0.16]
    # Higher income skews towards Platinum / Travel.
    probs[:, PLATINUM] *= 0.5 + 0.35 * income
    probs[:, TRAVEL] *= 0.8 + 0.15 * income
    probs /= probs.sum(axis=1, keepdims=True)
    u = rng.random(n)
    return (u[:, None] > probs.cumsum(axis=1)).sum(axis=1).clip(0, 3)


def simulate(n_accounts: int, n_months: int, start: str, seed: int) -> dict[str, pd.DataFrame]:
    rng = np.random.default_rng(seed)
    base = np.datetime64(start, "M")
    burn_in = 12  # simulated months before the window so the book starts seasoned

    # ---------------------------------------------------------------- customers
    n_customers = max(1, int(round(n_accounts * 0.86)))
    cust = build_customers(rng, n_customers)

    # Every customer gets one account; the remainder are second cards.
    acct_cust = np.concatenate(
        [np.arange(n_customers), rng.integers(0, n_customers, n_accounts - n_customers)]
    )
    is_secondary = np.arange(n_accounts) >= n_customers

    # Open month relative to `start` (negative = opened before the reporting window).
    open_m = np.where(
        rng.random(n_accounts) < 0.40,
        rng.integers(-48, 0, n_accounts),
        rng.integers(0, n_months, n_accounts),
    )
    primary_open = open_m[:n_customers]
    sec_open = primary_open[acct_cust[is_secondary]] + rng.integers(3, 25, is_secondary.sum())
    overflow = sec_open > n_months - 1
    sec_open[overflow] = rng.integers(
        np.minimum(primary_open[acct_cust[is_secondary]][overflow], n_months - 1), n_months
    )
    open_m[is_secondary] = sec_open
    open_day = rng.integers(0, 28, n_accounts)
    open_date = month_start(base, open_m) + open_day.astype("timedelta64[D]")

    age = cust["age"][acct_cust]
    income = cust["income"][acct_cust]
    channel = cust["channel"][acct_cust]
    product = choose_products(rng, age, income)
    # Second cards are rarely Student cards.
    swap = is_secondary & (product == STUDENT) & (rng.random(n_accounts) < 0.8)
    product[swap] = CASHBACK

    fico0 = (
        FICO_MEAN[product]
        + (income - 2) * 9.0
        - np.where(channel == 3, 12.0, 0.0)
        + rng.normal(0, 1, n_accounts) * FICO_SD[product]
    )
    fico0 = np.clip(np.round(fico0), 520, 850)

    fico_pct = (fico0 - 520) / 330
    score = np.clip(0.55 * fico_pct + 0.30 * income / 4 + 0.15 * rng.random(n_accounts), 0, 1)
    limit = LIMIT_LO[product] + (LIMIT_HI[product] - LIMIT_LO[product]) * score
    limit = np.where(product == STUDENT, np.round(limit / 50) * 50, np.round(limit / 100) * 100)

    apr = APR[product] + np.clip((700 - fico0) / 2000, -0.02, 0.04)

    # Behavioural segment: 0 = transactor, 1 = revolver, 2 = minimum payer.
    p_trans = np.clip(0.15 + (fico0 - 600) / 450 + np.isin(product, [TRAVEL, PLATINUM]) * 0.10, 0.05, 0.65)
    p_minpay = np.clip(0.24 - (fico0 - 600) / 650 + (product == STUDENT) * 0.06, 0.03, 0.35)
    u = rng.random(n_accounts)
    segment = np.where(u < p_trans, 0, np.where(u < p_trans + p_minpay, 2, 1))
    spend_rate = np.select(
        [segment == 0, segment == 1],
        [rng.uniform(0.08, 0.30, n_accounts), rng.uniform(0.03, 0.08, n_accounts)],
        rng.uniform(0.02, 0.05, n_accounts),
    ) * np.where(product == STUDENT, 1.3, 1.0)
    pay_frac = np.select([segment == 0, segment == 1], [1.0, rng.uniform(0.06, 0.25, n_accounts)], 0.0)

    # ------------------------------------------------------------------ state
    cyc = np.zeros(n_accounts, dtype=np.int64)  # delinquency cycle 0..6
    bal = np.zeros(n_accounts)
    stress = rng.normal(0, 0.9, n_accounts)
    fico_rw = np.zeros(n_accounts)
    alive = np.zeros(n_accounts, dtype=bool)
    charged_off = np.zeros(n_accounts, dtype=bool)
    co_month = np.full(n_accounts, -999)
    co_balance = np.zeros(n_accounts)

    statements: list[dict[str, np.ndarray]] = []

    for m in range(-burn_in, n_months):
        cal = int((base + np.timedelta64(m, "M")).astype(int) % 12)  # 0 = Jan
        macro = 0.12 * max(m, 0) / max(n_months - 1, 1)  # gentle late-cycle deterioration

        stress = 0.85 * stress + rng.normal(0, 0.48, n_accounts)
        fico_rw = 0.92 * fico_rw + rng.normal(0, 4.0, n_accounts)

        # Accounts entering the simulation this month.
        if m == -burn_in:
            new = (open_m <= m) & ~alive
            p_eq = spend_rate * limit
            eq_bal = np.where(
                segment == 0,
                p_eq,
                p_eq / np.maximum(1 - (1 - np.maximum(pay_frac, 0.02)) * (1 + apr / 12), 0.01),
            )
            bal[new] = np.minimum(eq_bal[new] * rng.lognormal(0, 0.25, new.sum()), limit[new] * 0.97)
        else:
            new = (open_m == m) & ~alive
            bal[new] = (spend_rate * limit * SPEND_SEASON[cal] * 0.6 * rng.lognormal(0, 0.35, n_accounts))[new]
            bal[new] = np.minimum(bal[new], limit[new])
        alive |= new
        cyc[new] = 0

        idx = np.flatnonzero(alive)
        c = cyc[idx]
        b = bal[idx]
        lim = limit[idx]
        s = stress[idx]

        # ------------------------------------------------ statement snapshot
        interest_est = b * apr[idx] / 12
        base_min = np.minimum(b, np.maximum(25.0, 0.01 * b + interest_est))
        min_due = np.minimum(b, base_min * (1 + np.minimum(c, 5)))
        dpd = np.where(c == 0, 0, 30 * c + rng.integers(0, 7, len(idx)))
        grace_late = (c == 0) & (b > 0) & (rng.random(len(idx)) < 0.05)
        dpd = np.where(grace_late, rng.integers(1, 30, len(idx)), dpd)
        dpd = np.where(c >= 6, 180, dpd)
        fico_t = np.clip(np.round(fico0[idx] + fico_rw[idx] - 28 * np.minimum(c, 4) - 6 * s), 300, 850)

        is_co = c >= 6
        util = b / lim

        # ------------------------------------------------ transition to m + 1
        u = rng.random(len(idx))
        logit = (
            -4.95
            - 0.0125 * (fico0[idx] - 700)
            + PRODUCT_RISK[product[idx]]
            + 0.85 * s
            + 2.4 * (util - 0.40)
            + RISK_SEASON[cal]
            + macro
            + np.where(channel[idx] == 3, 0.15, 0.0)
        )
        p_roll0 = sigmoid(logit)
        fico_adj = np.clip((650 - fico0[idx]) / 1000, -0.08, 0.10)
        cc = np.clip(c, 1, 5)
        p_cure = np.clip(CURE[cc] - fico_adj, 0.01, 0.9)
        p_stay = STAY[cc]

        nxt = np.where(
            c == 0,
            np.where(u < p_roll0, 1, 0),
            np.where(u < p_cure, 0, np.where(u < p_cure + p_stay, c, c + 1)),
        )
        nxt = np.where(is_co, 6, nxt)

        # Payment made against this statement (lands next month).
        r = rng.random(len(idx))
        revolver_pay = np.maximum(min_due, pay_frac[idx] * np.exp(-0.3 * s) * b)
        normal_pay = np.select(
            [segment[idx] == 0, segment[idx] == 1],
            [np.where(r < 0.9, b, revolver_pay), revolver_pay],
            min_due * rng.uniform(1.0, 1.1, len(idx)),
        )
        pay = np.select(
            [
                is_co,
                (c == 0) & (nxt == 0),
                (c == 0) & (nxt == 1),
                (c > 0) & (nxt == 0),
                (c > 0) & (nxt == c),
            ],
            [
                0.0,
                normal_pay,
                np.where(r < 0.75, 0.0, rng.uniform(0, 0.5, len(idx)) * min_due),
                min_due + rng.uniform(0, 0.2, len(idx)) * (b - min_due),
                rng.uniform(0.3, 0.9, len(idx)) * min_due,
            ],
            np.where(r < 0.8, 0.0, rng.uniform(0, 0.3, len(idx)) * min_due),
        )
        pay = np.round(np.minimum(pay, b), 2)

        statements.append(
            {
                "acct": idx,
                "m": np.full(len(idx), m),
                "balance": np.round(b, 2),
                "min_due": np.round(min_due, 2),
                "payment_amount": pay,
                "days_past_due": dpd,
                "fico_refresh": fico_t,
            }
        )

        # Charge-offs leave the book after their 180 DPD statement.
        co_idx = idx[is_co]
        charged_off[co_idx] = True
        alive[co_idx] = False
        co_month[co_idx] = m
        co_balance[co_idx] = b[is_co]

        # Balance roll-forward for surviving accounts.
        keep = ~is_co
        k_idx = idx[keep]
        rem = (b - pay)[keep]
        nxt_k = nxt[keep]
        interest = np.where(rem > 0.5, rem * apr[k_idx] / 12, 0.0)
        fee = np.where(nxt_k >= 1, LATE_FEE[product[k_idx]], 0.0)
        cal_next = (cal + 1) % 12
        purchases = (
            spend_rate[k_idx]
            * limit[k_idx]
            * SPEND_SEASON[cal_next]
            * np.exp(0.2 * s[keep])
            * rng.lognormal(0, 0.35, len(k_idx))
        )
        purchases *= np.select([nxt_k == 0, nxt_k == 1], [1.0, 0.3], 0.0)
        carried = rem + interest + fee
        purchases = np.minimum(purchases, np.maximum(0.0, limit[k_idx] - carried))  # declines at limit
        bal[k_idx] = np.minimum(carried + purchases, limit[k_idx] * 1.09)
        cyc[k_idx] = nxt_k

    # --------------------------------------------------------- assemble frames
    st = {k: np.concatenate([d[k] for d in statements]) for k in statements[0]}
    in_window = st["m"] >= 0
    st = {k: v[in_window] for k, v in st.items()}

    acct_ids = np.char.add("A", np.char.zfill(np.arange(1, n_accounts + 1).astype(str), 8))
    cust_ids = np.char.add("C", np.char.zfill(np.arange(1, n_customers + 1).astype(str), 7))

    stmt_month = month_start(base, st["m"])
    statements_df = pd.DataFrame(
        {
            "account_id": acct_ids[st["acct"]],
            "statement_month": stmt_month,
            "balance": st["balance"],
            "min_due": st["min_due"],
            "payment_amount": st["payment_amount"],
            "days_past_due": st["days_past_due"].astype(np.int64),
            "fico_refresh": pd.array(st["fico_refresh"].astype(np.int64), dtype="Int64"),
            "_loaded_at": (stmt_month + np.timedelta64(33, "D")).astype("datetime64[s]")
            + rng.integers(0, 6 * 3600, len(stmt_month)).astype("timedelta64[s]"),
        }
    )

    # Cycle payments: each statement payment arrives as 1-3 transactions next month.
    has_pay = st["payment_amount"] > 0
    p_acct = st["acct"][has_pay]
    p_m = st["m"][has_pay]
    p_amt = st["payment_amount"][has_pay]
    n_split = rng.choice([1, 2, 3], len(p_amt), p=[0.82, 0.14, 0.04])
    rep = np.repeat(np.arange(len(p_amt)), n_split)
    weights = rng.uniform(0.2, 1.0, len(rep))
    wsum = np.bincount(rep, weights=weights)
    amt = np.round(p_amt[rep] * weights / wsum[rep], 2)
    # Push rounding residue onto the first split so splits sum exactly to the statement payment.
    first = np.r_[True, rep[1:] != rep[:-1]]
    residue = np.round(p_amt - np.bincount(rep, weights=amt), 2)
    amt[first] = np.round(amt[first] + residue, 2)
    pay_date = month_start(base, p_m[rep] + 1) + rng.integers(0, 28, len(rep)).astype("timedelta64[D]")
    cycle_payments = pd.DataFrame({"acct": p_acct[rep], "payment_date": pay_date, "amount": amt})

    # Post-charge-off recoveries, only for charge-offs inside the reporting window (a recovery
    # cannot be attributed to a charge-off the extract never reports).
    co_accts = np.flatnonzero(charged_off & (co_month >= 0))
    recovering = co_accts[rng.random(len(co_accts)) < 0.35]
    n_rec = rng.integers(1, 7, len(recovering))
    rec_rep = np.repeat(np.arange(len(recovering)), n_rec)
    rec_total = co_balance[recovering] * rng.uniform(0.05, 0.35, len(recovering))
    rec_amt = np.round(rec_total[rec_rep] / n_rec[rec_rep], 2)
    rec_offset = rng.integers(2, 13, len(rec_rep))
    rec_date = month_start(base, co_month[recovering][rec_rep] + rec_offset) + rng.integers(
        0, 28, len(rec_rep)
    ).astype("timedelta64[D]")
    recoveries = pd.DataFrame({"acct": recovering[rec_rep], "payment_date": rec_date, "amount": rec_amt})

    as_of = month_start(base, n_months + 1) - np.timedelta64(1, "D")  # end of month after window
    payments_df = pd.concat([cycle_payments, recoveries], ignore_index=True)
    payments_df = payments_df[(payments_df["payment_date"] <= as_of) & (payments_df["amount"] > 0)]
    payments_df = payments_df.sort_values(["payment_date", "acct"], kind="stable").reset_index(drop=True)
    payments_df.insert(0, "payment_id", np.char.add("P", np.char.zfill(np.arange(1, len(payments_df) + 1).astype(str), 9)))
    payments_df.insert(1, "account_id", acct_ids[payments_df.pop("acct").to_numpy()])
    payments_df["_loaded_at"] = (payments_df["payment_date"].to_numpy().astype("datetime64[s]") + np.timedelta64(1, "D")) + rng.integers(
        0, 12 * 3600, len(payments_df)
    ).astype("timedelta64[s]")

    accounts_df = pd.DataFrame(
        {
            "account_id": acct_ids,
            "customer_id": cust_ids[acct_cust],
            "product": PRODUCTS[product],
            "credit_limit": limit,
            "open_date": open_date,
            "fico_at_origination": fico0.astype(np.int64),
            "_loaded_at": (np.maximum(open_date, month_start(base, -burn_in)) + np.timedelta64(1, "D")).astype("datetime64[s]"),
        }
    )

    cust_open = pd.Series(open_date).groupby(acct_cust).min().to_numpy()
    customers_df = pd.DataFrame(
        {
            "customer_id": cust_ids,
            "state": cust["states"][cust["state_idx"]],
            "age_band": AGE_BANDS[cust["age"]],
            "income_band": INCOME_BANDS[cust["income"]],
            "acquisition_channel": CHANNELS[cust["channel"]],
            "open_date": cust_open,
            "_loaded_at": (np.maximum(cust_open, month_start(base, -burn_in)) + np.timedelta64(1, "D")).astype("datetime64[s]"),
        }
    )

    return {
        "raw_customers": customers_df,
        "raw_accounts": accounts_df,
        "raw_statements": statements_df,
        "raw_payments": payments_df,
    }


def inject_dq_issues(frames: dict[str, pd.DataFrame], rng: np.random.Generator) -> dict[str, int]:
    """Inject realistic data-quality defects. Returns counts for the run log."""
    st = frames["raw_statements"]
    pay = frames["raw_payments"]
    n_st, n_pay = len(st), len(pay)
    log: dict[str, int] = {}

    # 1. Null FICO refreshes (bureau feed gaps).
    null_mask = rng.random(n_st) < 0.007
    st.loc[null_mask, "fico_refresh"] = pd.NA
    log["statements_null_fico_refresh"] = int(null_mask.sum())

    # 2. Restatements: a preliminary (wrong) version loaded on time, the corrected
    #    version arrives late. Staging must keep the latest load.
    restate = rng.choice(n_st, int(n_st * 0.003), replace=False)
    prelim = st.iloc[restate].copy()
    prelim["balance"] = np.round(prelim["balance"] * rng.uniform(0.6, 1.6, len(prelim)), 2)
    prelim["days_past_due"] = np.maximum(0, prelim["days_past_due"] - 30 * rng.integers(0, 2, len(prelim)))
    st.loc[st.index[restate], "_loaded_at"] = st["_loaded_at"].iloc[restate] + pd.to_timedelta(
        rng.integers(30, 121, len(restate)), unit="D"
    )
    log["statements_restated_late"] = len(restate)

    # 3. Late-arriving statements (correct values, loaded weeks after the cycle).
    late = rng.choice(n_st, int(n_st * 0.002), replace=False)
    st.loc[st.index[late], "_loaded_at"] = st["_loaded_at"].iloc[late] + pd.to_timedelta(
        rng.integers(20, 90, len(late)), unit="D"
    )
    log["statements_late_arriving"] = len(late)

    # 4. Exact duplicate statement rows (re-sent files).
    dup = st.iloc[rng.choice(n_st, int(n_st * 0.004), replace=False)]
    log["statements_exact_duplicates"] = len(dup)
    st = pd.concat([st, prelim, dup], ignore_index=True)
    # Late loads physically land at the end of the extract.
    st = st.sort_values("_loaded_at", kind="stable").reset_index(drop=True)

    # 5. Negative payments (reversal noise from the processor feed).
    neg = pay.iloc[rng.choice(n_pay, int(n_pay * 0.005), replace=False)].copy()
    neg["amount"] = -neg["amount"]
    neg["payment_id"] = np.char.add("PX", np.char.zfill(np.arange(1, len(neg) + 1).astype(str), 8))
    log["payments_negative"] = len(neg)

    # 6. Duplicate payment records (same payment_id re-delivered).
    pdup = pay.iloc[rng.choice(n_pay, int(n_pay * 0.002), replace=False)].copy()
    pdup["_loaded_at"] = pdup["_loaded_at"] + pd.to_timedelta(rng.integers(1, 5, len(pdup)), unit="D")
    log["payments_duplicate_id"] = len(pdup)

    # 7. Orphan payments referencing accounts that do not exist.
    orphan = pay.iloc[rng.choice(n_pay, max(1, int(n_pay * 0.0005)), replace=False)].copy()
    orphan["account_id"] = np.char.add("A9", np.char.zfill(np.arange(1, len(orphan) + 1).astype(str), 7))
    orphan["payment_id"] = np.char.add("PO", np.char.zfill(np.arange(1, len(orphan) + 1).astype(str), 8))
    log["payments_orphan_account"] = len(orphan)

    # 8. Late-arriving payments.
    late_pay = rng.random(n_pay) < 0.003
    pay.loc[late_pay, "_loaded_at"] = pay.loc[late_pay, "_loaded_at"] + pd.to_timedelta(
        rng.integers(15, 60, late_pay.sum()), unit="D"
    )
    log["payments_late_arriving"] = int(late_pay.sum())

    pay = pd.concat([pay, neg, pdup, orphan], ignore_index=True)
    pay = pay.sort_values("_loaded_at", kind="stable").reset_index(drop=True)

    frames["raw_statements"] = st
    frames["raw_payments"] = pay
    return log


def write_csv(df: pd.DataFrame, path: Path) -> None:
    con = duckdb.connect()
    con.register("df", df)
    con.execute(
        f"COPY (SELECT * FROM df) TO '{path.as_posix()}' "
        "(HEADER, DELIMITER ',', DATEFORMAT '%Y-%m-%d', TIMESTAMPFORMAT '%Y-%m-%d %H:%M:%S')"
    )
    con.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--accounts", type=int, default=50_000, help="number of card accounts (default 50,000)")
    parser.add_argument("--months", type=int, default=36, help="reporting months (default 36)")
    parser.add_argument("--start", default="2023-01", help="first reporting month YYYY-MM (default 2023-01)")
    parser.add_argument("--seed", type=int, default=42, help="random seed (default 42)")
    parser.add_argument("--out", type=Path, default=Path("data/raw"), help="output directory")
    parser.add_argument("--no-dq", action="store_true", help="skip data-quality defect injection")
    args = parser.parse_args()

    t0 = time.time()
    frames = simulate(args.accounts, args.months, args.start, args.seed)
    dq_log = {} if args.no_dq else inject_dq_issues(frames, np.random.default_rng(args.seed + 1))

    args.out.mkdir(parents=True, exist_ok=True)
    for name, df in frames.items():
        write_csv(df, args.out / f"{name}.csv")
        print(f"  {name:<16} {len(df):>12,} rows")
    for issue, n in dq_log.items():
        print(f"  dq: {issue:<32} {n:>8,}")
    print(f"Wrote raw extracts to {args.out}/ in {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()

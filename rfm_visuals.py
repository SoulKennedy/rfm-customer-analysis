"""
RFM visuals
1. Customer share vs revenue share by segment (paired bars)
2. Revenue concentration (Pareto curve)

Setup:  pip install pandas matplotlib sqlalchemy pymysql
Run:    python rfm_visuals.py
"""

import os
from getpass import getpass
from urllib.parse import quote_plus

import matplotlib.pyplot as plt
import pandas as pd
from matplotlib.patches import Patch
from sqlalchemy import create_engine


# Settings
HOST, PORT, USER, DATABASE = "localhost", 3306, "root", "rfm_project"
PASSWORD = os.getenv("MYSQL_PASSWORD") or getpass("MySQL password: ")

SEGMENT_ORDER = [
    "At Risk",
    "Need Attention",
    "Best Customers",
    "Loyal Customers",
    "Potential Loyal Customers",
]
RISK_SEGMENTS = {"At Risk", "Need Attention"}

GREY, BLUE, RED = "#B8BEC6", "#2F5D8C", "#D9534F"


# Load data -- from mysql server
engine = create_engine(
    f"mysql+pymysql://{USER}:{quote_plus(PASSWORD)}@{HOST}:{PORT}/{DATABASE}"
)

df = pd.read_sql(
    """
    SELECT
        Customer_ID,
        MAX(RFM_Category)          AS RFM_Category,
        MAX(COALESCE(Monetary, 0)) AS Monetary
    FROM customer_rfm
    GROUP BY Customer_ID
    """,
    engine,
)
df["Monetary"] = df["Monetary"].astype(float)
df["RFM_Category"] = df["RFM_Category"].fillna("Unclassified")

total_customers = len(df)
total_revenue = df["Monetary"].sum()


# Chart 1: customer share vs revenue share
seg = (
    df.groupby("RFM_Category")
    .agg(customers=("Customer_ID", "count"), revenue=("Monetary", "sum"))
    .reset_index()
)
seg["customer_pct"] = seg["customers"] / total_customers * 100
seg["revenue_pct"] = seg["revenue"] / total_revenue * 100

order = [s for s in SEGMENT_ORDER if s in set(seg["RFM_Category"])]
order += [s for s in seg["RFM_Category"] if s not in order]
seg = seg.set_index("RFM_Category").loc[order].reset_index()

x = range(len(seg))
w = 0.38
fig, ax = plt.subplots(figsize=(11, 6))

cust_bars = ax.bar([i - w / 2 for i in x], seg["customer_pct"], w, color=GREY)
rev_colors = [RED if s in RISK_SEGMENTS else BLUE for s in seg["RFM_Category"]]
rev_bars = ax.bar([i + w / 2 for i in x], seg["revenue_pct"], w, color=rev_colors)

ax.bar_label(cust_bars, fmt="%.1f%%", padding=3, fontsize=9)
ax.bar_label(rev_bars, fmt="%.1f%%", padding=3, fontsize=9, fontweight="bold")

ax.set_xticks(list(x))
ax.set_xticklabels(
    [s.replace(" Customers", "").replace("Potential Loyal", "Potential\nLoyal") for s in seg["RFM_Category"]]
)
ax.set_ylabel("% of total")
ax.spines[["top", "right"]].set_visible(False)
ax.legend(
    handles=[
        Patch(color=GREY, label="% of customers"),
        Patch(color=BLUE, label="% of revenue"),
        Patch(color=RED, label="% of revenue (retention risk)"),
    ],
    frameon=False,
)

# Auto headline: top revenue-driving segment
top = seg.loc[seg["revenue_pct"].idxmax()]
risk = seg[seg["RFM_Category"].isin(RISK_SEGMENTS)]
fig.suptitle(
    f"{top['RFM_Category']}: {top['customer_pct']:.0f}% of customers, "
    f"{top['revenue_pct']:.0f}% of revenue",
    fontsize=15,
    fontweight="bold",
    x=0.07,
    ha="left",
)
ax.set_title(
    f"{risk['revenue_pct'].sum():.0f}% of revenue sits in retention-risk segments "
    f"({risk['customers'].sum():,} customers)",
    loc="left",
    fontsize=11,
    color="#555555",
)
fig.tight_layout()
fig.savefig("rfm_segment_share.png", dpi=200)


# Chart 2: Pareto curve
p = df.sort_values("Monetary", ascending=False).reset_index(drop=True)
p["cum_customer_pct"] = (p.index + 1) / total_customers * 100
p["cum_revenue_pct"] = p["Monetary"].cumsum() / total_revenue * 100

at80 = p[p["cum_revenue_pct"] >= 80].iloc[0]

fig2, ax2 = plt.subplots(figsize=(8, 6))
ax2.plot([0, 100], [0, 100], linestyle="--", color=GREY, label="Perfect equality")
ax2.plot(p["cum_customer_pct"], p["cum_revenue_pct"], color=BLUE, linewidth=2.5, label="Actual revenue")
ax2.axhline(80, color=RED, linewidth=0.8, linestyle=":")
ax2.scatter([at80["cum_customer_pct"]], [80], color=RED, zorder=5)
ax2.annotate(
    f"{at80['cum_customer_pct']:.0f}% of customers\ngenerate 80% of revenue",
    xy=(at80["cum_customer_pct"], 80),
    xytext=(at80["cum_customer_pct"] + 8, 62),
    arrowprops=dict(arrowstyle="->", color=RED),
    color=RED,
    fontweight="bold",
)
ax2.set_xlabel("Cumulative % of customers (highest value first)")
ax2.set_ylabel("Cumulative % of revenue")
ax2.set_xlim(0, 100)
ax2.set_ylim(0, 100)
ax2.spines[["top", "right"]].set_visible(False)
ax2.legend(frameon=False, loc="lower right")
ax2.set_title("Revenue concentration", loc="left", fontsize=15, fontweight="bold")
fig2.tight_layout()
fig2.savefig("rfm_pareto.png", dpi=200)

print("Saved: rfm_segment_share.png, rfm_pareto.png")
plt.show()

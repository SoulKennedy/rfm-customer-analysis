USE rfm_project;

-- Reset temp tables
DROP TEMPORARY TABLE IF EXISTS tmp_rfm;
DROP TEMPORARY TABLE IF EXISTS tmp_totals;
DROP TEMPORARY TABLE IF EXISTS tmp_segment_map;
DROP TEMPORARY TABLE IF EXISTS tmp_segment_summary;

-- Data quality check (expect 0 rows)
SELECT
    Customer_ID,
    COUNT(*)                     AS row_count,
    COUNT(DISTINCT RFM_Category) AS distinct_categories,
    COUNT(DISTINCT Monetary)     AS distinct_monetary
FROM customer_rfm
GROUP BY Customer_ID
HAVING COUNT(*) > 1
   AND (COUNT(DISTINCT RFM_Category) > 1 OR COUNT(DISTINCT Monetary) > 1);

-- Customer-level RFM base
CREATE TEMPORARY TABLE tmp_rfm AS
SELECT
    Customer_ID,
    MAX(RFM_Category)          AS RFM_Category,
    MAX(Recency)               AS Recency,
    MAX(Frequency)             AS Frequency,
    MAX(COALESCE(Monetary, 0)) AS Monetary
FROM customer_rfm
GROUP BY Customer_ID;

ALTER TABLE tmp_rfm ADD INDEX idx_category (RFM_Category(50));

-- Business totals
CREATE TEMPORARY TABLE tmp_totals AS
SELECT
    NULLIF(COUNT(*), 0)      AS total_customers,
    NULLIF(SUM(Monetary), 0) AS total_revenue
FROM tmp_rfm;

-- Segment lookup
CREATE TEMPORARY TABLE tmp_segment_map (
    RFM_Category        VARCHAR(50) PRIMARY KEY,
    display_order       TINYINT,
    priority_order      TINYINT,
    strategic_action    VARCHAR(30),
    management_priority VARCHAR(20),
    retention_action    VARCHAR(30)
);

INSERT INTO tmp_segment_map VALUES
    ('Best Customers',            1, 3, 'PROTECT & REWARD',   'PROTECT',       NULL),
    ('Loyal Customers',           2, 4, 'GROW & RETAIN',      'GROW',          NULL),
    ('Potential Loyal Customers', 3, 5, 'DEVELOP',            'DEVELOP',       NULL),
    ('Need Attention',            4, 2, 'RETENTION CAMPAIGN', 'HIGH PRIORITY', 'PREVENTIVE RETENTION'),
    ('At Risk',                   5, 1, 'URGENT WIN-BACK',    'HIGH PRIORITY', 'URGENT WIN-BACK');

-- Segment summary
CREATE TEMPORARY TABLE tmp_segment_summary AS
SELECT
    COALESCE(r.RFM_Category, 'Unclassified')          AS RFM_Category,
    COALESCE(m.display_order, 99)                     AS display_order,
    COALESCE(m.priority_order, 99)                    AS priority_order,
    COALESCE(m.strategic_action, 'REVIEW')            AS strategic_action,
    COALESCE(m.management_priority, 'REVIEW')         AS management_priority,
    COUNT(*)                                          AS customer_count,
    ROUND(COUNT(*) / t.total_customers * 100, 2)      AS customer_share_pct,
    ROUND(SUM(r.Monetary), 2)                         AS total_revenue,
    ROUND(SUM(r.Monetary) / t.total_revenue * 100, 2) AS revenue_share_pct,
    ROUND(AVG(r.Monetary), 2)                         AS avg_customer_value,
    ROUND(AVG(r.Recency), 2)                          AS avg_recency,
    ROUND(AVG(r.Frequency), 2)                        AS avg_frequency
FROM tmp_rfm r
CROSS JOIN tmp_totals t
LEFT JOIN tmp_segment_map m ON m.RFM_Category = r.RFM_Category
GROUP BY
    COALESCE(r.RFM_Category, 'Unclassified'),
    m.display_order, m.priority_order, m.strategic_action, m.management_priority,
    t.total_customers, t.total_revenue;

-- Segment performance overview
SELECT
    RFM_Category, customer_count, customer_share_pct, total_revenue,
    revenue_share_pct, avg_customer_value, avg_recency, avg_frequency,
    strategic_action
FROM tmp_segment_summary
ORDER BY display_order;

-- Q1: Best customers
SELECT
    Customer_ID,
    RFM_Category,
    Recency,
    Frequency,
    Monetary,
    RANK() OVER (ORDER BY Monetary DESC) AS value_rank
FROM tmp_rfm
WHERE RFM_Category = 'Best Customers'
ORDER BY value_rank, Customer_ID;

-- Q2: Retention customers
SELECT
    r.Customer_ID,
    r.RFM_Category,
    r.Recency,
    r.Frequency,
    r.Monetary,
    m.retention_action,
    RANK() OVER (PARTITION BY r.RFM_Category ORDER BY r.Monetary DESC) AS value_rank_in_segment
FROM tmp_rfm r
JOIN tmp_segment_map m ON m.RFM_Category = r.RFM_Category
WHERE m.retention_action IS NOT NULL
ORDER BY m.priority_order, r.Monetary DESC, r.Customer_ID;

-- Q2: Revenue at risk
SELECT
    CASE WHEN GROUPING(r.RFM_Category) = 1
         THEN 'ALL RETENTION SEGMENTS'
         ELSE r.RFM_Category
    END                                                          AS RFM_Category,
    COUNT(*)                                                     AS retention_customers,
    ROUND(COUNT(*) / MAX(t.total_customers) * 100, 2)            AS customer_share_pct,
    ROUND(SUM(r.Monetary), 2)                                    AS revenue_at_risk,
    ROUND(SUM(r.Monetary) / MAX(t.total_revenue) * 100, 2)       AS revenue_at_risk_pct
FROM tmp_rfm r
JOIN tmp_segment_map m ON m.RFM_Category = r.RFM_Category
CROSS JOIN tmp_totals t
WHERE m.retention_action IS NOT NULL
GROUP BY r.RFM_Category WITH ROLLUP;

-- Q3: Segment priority
SELECT
    RFM_Category,
    customer_count,
    customer_share_pct,
    total_revenue,
    revenue_share_pct,
    management_priority
FROM tmp_segment_summary
ORDER BY priority_order, total_revenue DESC;

-- Q4: Revenue by segment
SELECT
    RFM_Category,
    customer_count,
    total_revenue AS segment_revenue,
    revenue_share_pct,
    DENSE_RANK() OVER (ORDER BY total_revenue DESC) AS revenue_rank
FROM tmp_segment_summary
ORDER BY segment_revenue DESC;

-- Q5: Customer revenue concentration
WITH ranked_customers AS (
    SELECT
        Customer_ID,
        RFM_Category,
        Monetary,
        ROW_NUMBER() OVER (ORDER BY Monetary DESC, Customer_ID) AS customer_rank
    FROM tmp_rfm
),
cumulative AS (
    SELECT
        rc.*,
        SUM(Monetary) OVER (
            ORDER BY customer_rank
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_revenue
    FROM ranked_customers rc
)
SELECT
    c.Customer_ID,
    c.RFM_Category,
    c.Monetary,
    ROUND(c.Monetary / t.total_revenue * 100, 2)           AS revenue_share_pct,
    c.customer_rank,
    ROUND(c.cumulative_revenue, 2)                         AS cumulative_revenue,
    ROUND(c.cumulative_revenue / t.total_revenue * 100, 2) AS cumulative_revenue_pct,
    ROUND(c.customer_rank / t.total_customers * 100, 2)    AS cumulative_customer_pct
FROM cumulative c
CROSS JOIN tmp_totals t
ORDER BY c.customer_rank;

-- Q5: Top customer concentration
WITH ranked AS (
    SELECT
        Monetary,
        ROW_NUMBER() OVER (ORDER BY Monetary DESC, Customer_ID) AS customer_rank,
        SUM(Monetary) OVER (
            ORDER BY Monetary DESC, Customer_ID
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cum_revenue
    FROM tmp_rfm
),
concentration AS (
    SELECT
        MAX(t.total_customers) AS total_customers,
        MAX(t.total_revenue)   AS total_revenue,
        SUM(CASE WHEN customer_rank <= CEIL(t.total_customers * 0.05) THEN Monetary ELSE 0 END) AS top_5_revenue,
        SUM(CASE WHEN customer_rank <= CEIL(t.total_customers * 0.10) THEN Monetary ELSE 0 END) AS top_10_revenue,
        SUM(CASE WHEN customer_rank <= CEIL(t.total_customers * 0.20) THEN Monetary ELSE 0 END) AS top_20_revenue,
        SUM(CASE WHEN customer_rank <= CEIL(t.total_customers * 0.50) THEN Monetary ELSE 0 END) AS top_50_revenue,
        MIN(CASE WHEN cum_revenue >= t.total_revenue * 0.80 THEN customer_rank END)             AS customers_for_80pct_revenue
    FROM ranked r
    CROSS JOIN tmp_totals t
)
SELECT
    ROUND(top_5_revenue, 2)                                       AS top_5_revenue,
    ROUND(top_5_revenue  / total_revenue * 100, 2)                AS top_5_revenue_pct,
    ROUND(top_10_revenue, 2)                                      AS top_10_revenue,
    ROUND(top_10_revenue / total_revenue * 100, 2)                AS top_10_revenue_pct,
    ROUND(top_20_revenue, 2)                                      AS top_20_revenue,
    ROUND(top_20_revenue / total_revenue * 100, 2)                AS top_20_revenue_pct,
    ROUND(top_50_revenue, 2)                                      AS top_50_revenue,
    ROUND(top_50_revenue / total_revenue * 100, 2)                AS top_50_revenue_pct,
    customers_for_80pct_revenue,
    ROUND(customers_for_80pct_revenue / total_customers * 100, 2) AS pct_of_customers_for_80pct_revenue,
    CASE
        WHEN top_20_revenue / total_revenue >= 0.70 THEN 'VERY HIGH CONCENTRATION'
        WHEN top_20_revenue / total_revenue >= 0.50 THEN 'HIGH CONCENTRATION'
        WHEN top_20_revenue / total_revenue >= 0.40 THEN 'MODERATE CONCENTRATION'
        ELSE 'LOWER CONCENTRATION'
    END AS concentration_assessment
FROM concentration;
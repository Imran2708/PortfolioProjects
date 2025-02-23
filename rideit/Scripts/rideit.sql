-- RideIT Driver Engagement Analysis
-- Portfolio Project demonstrating data cleaning and metric analysis for ride-sharing driver engagement

-- 1. DATABASE SETUP
CREATE DATABASE rideit;
USE rideit;

-- 2. DATA QUALITY ASSESSMENT
-- Check for missing values in drivers table
SELECT 
    SUM(CASE WHEN driver_rating IS NULL THEN 1 ELSE 0 END) AS missing_driver_rating,
    ROUND(((COUNT(*) - COUNT(driver_rating)) * 100.0) / COUNT(*), 2) AS percent_missing_driver_rating,
    SUM(CASE WHEN gold_level_count IS NULL THEN 1 ELSE 0 END) AS missing_goldlevel_count,
    ROUND(((COUNT(*) - COUNT(gold_level_count)) * 100.0) / COUNT(*), 2) AS percent_missing_goldlevel_count
FROM drivers;

-- 3. DATA PREPARATION
-- Create backup tables for data manipulation
SELECT * INTO drivers_copy FROM drivers;
SELECT * INTO activity_copy FROM activity;

-- Replace missing driver_rating values with median
WITH mediancte AS (
    SELECT DISTINCT
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY driver_rating)
        OVER() AS median_value
    FROM drivers_copy
    WHERE driver_rating IS NOT NULL
) 
UPDATE drivers_copy
SET driver_rating = (SELECT median_value FROM mediancte)
WHERE driver_rating IS NULL;

-- Replace missing gold_level_count values with median
WITH mediancte AS (
    SELECT DISTINCT
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY gold_level_count)
        OVER() AS median_value
    FROM drivers_copy
    WHERE gold_level_count IS NOT NULL
) 
UPDATE drivers_copy
SET gold_level_count = (SELECT median_value FROM mediancte)
WHERE gold_level_count IS NULL;

-- 4. DRIVER ENGAGEMENT METRICS

-- 4.1 Volume Metrics
-- Total unique drivers
SELECT COUNT(DISTINCT id_driver) AS total_drivers
FROM drivers_copy;

-- Service distribution
SELECT service_type, COUNT(service_type) AS total_services
FROM drivers_copy
GROUP BY service_type;

-- Geographic distribution
SELECT country_code, COUNT(country_code) AS total_drivers_by_country
FROM drivers_copy
GROUP BY country_code;

-- Marketing engagement
SELECT COUNT(receive_marketing) AS marketing_enabled_drivers
FROM drivers_copy
WHERE receive_marketing = 1;

-- 4.2 Activity Metrics
-- Total rides and bookings
SELECT 
    SUM(rides) AS completed_rides,
    SUM(bookings) AS total_bookings,
    SUM(offers) AS total_rides_requested
FROM activity_copy;

-- Monthly active drivers and rides
SELECT 
    MONTH(active_date) AS month,
    COUNT(DISTINCT id_driver) AS monthly_active_drivers,
    SUM(rides) AS monthly_rides
FROM activity_copy
GROUP BY MONTH(active_date)
ORDER BY month;

-- Driver activity levels
SELECT
    id_driver,
    COUNT(DISTINCT active_date) as active_days,
    SUM(rides) as total_rides,
    ROUND(AVG(rides), 2) as avg_rides_per_active_day
FROM activity_copy
GROUP BY id_driver
ORDER BY active_days DESC;

-- 4.3 Rating Analysis
-- Overall rating distribution
SELECT 
    driver_rating,
    COUNT(*) as frequency,
    CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) as percentage
FROM drivers_copy
GROUP BY driver_rating
ORDER BY driver_rating;

-- Average rating by service type and country
SELECT
    service_type,
    country_code,
    ROUND(AVG(driver_rating), 2) AS avg_driver_rating,
    COUNT(*) as driver_count
FROM drivers_copy
GROUP BY service_type, country_code;

-- 4.4 Cancellation Analysis
-- Overall cancellation metrics
SELECT
    SUM(bookings_cancelled_by_driver) AS driver_cancellations,
    SUM(bookings_cancelled_by_passenger) AS passenger_cancellations,
    SUM(bookings_cancelled_by_driver + bookings_cancelled_by_passenger) AS total_cancellations
FROM activity_copy;

-- Cancellation rates by service type
SELECT
    d.service_type,
    SUM(a.bookings_cancelled_by_driver) AS driver_cancellation,
    SUM(a.bookings_cancelled_by_passenger) AS passenger_cancellation,
    ROUND(CAST(SUM(a.bookings_cancelled_by_driver + a.bookings_cancelled_by_passenger) AS FLOAT) / 
          NULLIF(SUM(a.bookings), 0) * 100, 2) as cancellation_rate
FROM drivers_copy d
JOIN activity_copy a ON d.id_driver = a.id_driver
GROUP BY d.service_type;

--KPIs

 -- 1. DRIVER RETENTION RATE
/* Purpose: Measures how well we retain drivers month over month
   Business Value: 
   - Key indicator of driver satisfaction and platform sustainability
   - Higher retention = lower acquisition costs
   - Helps identify seasonal patterns and potential churn risks
*/

WITH MonthlyActiveDrivers AS (
    SELECT 
        id_driver,
        DATEADD(MONTH, DATEDIFF(MONTH, 0, active_date), 0) as month,
        SUM(rides) as total_rides
    FROM activity_copy
    WHERE rides > 0
    GROUP BY id_driver, DATEADD(MONTH, DATEDIFF(MONTH, 0, active_date), 0)
)
SELECT 
    month,
    COUNT(DISTINCT id_driver) as current_drivers,
    LAG(COUNT(DISTINCT id_driver)) OVER (ORDER BY month) as prev_month_drivers,
    CAST(ROUND(
        (COUNT(DISTINCT id_driver) * 100.0) / 
        NULLIF(LAG(COUNT(DISTINCT id_driver)) OVER (ORDER BY month), 0), 
        2) AS DECIMAL(10,2)) as retention_rate
FROM MonthlyActiveDrivers
GROUP BY month
ORDER BY month;

-- 2. DRIVER UTILIZATION RATE
/* Purpose: Measures efficiency of driver time on platform
   Business Value:
   - Indicates platform efficiency in matching drivers to rides
   - Helps optimize driver supply vs demand
   - Key for driver earnings potential
*/

WITH driver_activity_agg AS (
    SELECT 
        id_driver, 
        CAST(active_date AS DATE) AS active_date,  -- Truncate to date if active_date includes time info
        SUM(bookings) AS accepted_rides,
        SUM(offers) AS total_offers
    FROM activity_copy
    GROUP BY id_driver, CAST(active_date AS DATE)
)
SELECT 
    da.id_driver,
    da.active_date,
    da.accepted_rides,
    da.total_offers,
    CAST(ROUND((da.accepted_rides * 100.0) / NULLIF(da.total_offers, 0), 2) AS DECIMAL(10,2)) AS utilization_rate,
    d.service_type,
    d.driver_rating
FROM driver_activity_agg da
JOIN drivers_copy d ON da.id_driver = d.id_driver
ORDER BY utilization_rate DESC;


-- 3. CANCELLATION ANALYSIS
/* Purpose: Analyzes cancellation patterns and their impact
   Business Value:
   - Identifies potential service quality issues
   - Helps reduce revenue leakage
   - Improves customer experience
*/

SELECT 
    a.id_driver,
    d.service_type,
    COUNT(DISTINCT a.active_date) as active_days,
    SUM(a.bookings) as total_bookings,
    SUM(a.bookings_cancelled_by_driver) as driver_cancellations,
    SUM(a.bookings_cancelled_by_passenger) as passenger_cancellations,
    CAST(ROUND(
        (SUM(a.bookings_cancelled_by_driver) * 100.0) / NULLIF(SUM(a.bookings), 0),
        2) AS DECIMAL(10,2)) as driver_cancellation_rate,
    d.driver_rating
FROM activity_copy a
JOIN drivers_copy d ON a.id_driver = d.id_driver
GROUP BY 
    a.id_driver,
    d.service_type,
    d.driver_rating
ORDER BY driver_cancellation_rate DESC;

-- 4. DRIVER PERFORMANCE SEGMENTS
/* Purpose: Segments drivers based on key performance metrics
   Business Value:
   - Identifies top performers and their characteristics
   - Helps create targeted improvement programs
   - Guides incentive program design
*/

WITH DriverMetrics AS (
    SELECT 
        a.id_driver,
        COUNT(DISTINCT a.active_date) as active_days,
        SUM(a.rides) as total_rides,
        SUM(a.bookings) as total_bookings,
        d.driver_rating,
        d.gold_level_count,
        d.service_type,
        CAST(ROUND(
            (SUM(a.rides) * 1.0) / COUNT(DISTINCT a.active_date),
            2) AS DECIMAL(10,2)) as rides_per_active_day
    FROM activity_copy a
    JOIN drivers_copy d ON a.id_driver = d.id_driver
    GROUP BY 
        a.id_driver,
        d.driver_rating,
        d.gold_level_count,
        d.service_type
)
SELECT 
    CASE 
        WHEN rides_per_active_day >= 8 AND driver_rating >= 4.5 THEN 'High Performer'
        WHEN rides_per_active_day >= 5 AND driver_rating >= 4.0 THEN 'Good Performer'
        WHEN rides_per_active_day >= 3 THEN 'Average Performer'
        ELSE 'Needs Improvement'
    END as performance_segment,
    COUNT(*) as driver_count,
    AVG(driver_rating) as avg_rating,
    AVG(rides_per_active_day) as avg_rides_per_day,
    AVG(gold_level_count) as avg_gold_achievements
FROM DriverMetrics
GROUP BY 
    CASE 
        WHEN rides_per_active_day >= 8 AND driver_rating >= 4.5 THEN 'High Performer'
        WHEN rides_per_active_day >= 5 AND driver_rating >= 4.0 THEN 'Good Performer'
        WHEN rides_per_active_day >= 3 THEN 'Average Performer'
        ELSE 'Needs Improvement'
    END
ORDER BY avg_rides_per_day DESC;
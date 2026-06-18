DROP VIEW IF EXISTS youtube_data_schema.vw_base_clean CASCADE;
DROP VIEW IF EXISTS youtube_data_schema.vw_market_opportunity CASCADE;
DROP VIEW IF EXISTS youtube_data_schema.vw_kenya_global_comparison CASCADE;
DROP VIEW IF EXISTS youtube_data_schema.vw_breakthrough_video CASCADE;
DROP VIEW IF EXISTS youtube_data_schema.vw_content_decay CASCADE;
DROP VIEW IF EXISTS youtube_data_schema.vw_channel_features CASCADE;
DROP VIEW IF EXISTS youtube_data_schema.vw_nlp_features CASCADE;
DROP VIEW IF EXISTS youtube_data_schema.vw_upload_timing CASCADE;
DROP VIEW IF EXISTS youtube_data_schema.vw_translation_queue CASCADE;

-- ============================================================================
-- 1. BASE CLEANED VIEW (The Ground-Floor Data Quality Gatekeeper)
-- ============================================================================
-- ML Context: This serves as your feature store foundation. It enforces explicit
--             data types (bigint, numeric, integer, boolean) ensuring that when
--             Pandas/NumPy loads this data, arrays match expected memory profiles
--             and do not throw implicit object-type conversion errors.
-- ============================================================================
CREATE OR REPLACE VIEW youtube_data_schema.vw_base_clean AS
SELECT
    TRIM(video_id::text) AS video_id,
    TRIM(channel_id::text) AS channel_id,
    COALESCE(TRIM(channel_title::text), '[Unknown Channel]') AS channel_title,
    COALESCE(TRIM(video_title::text), '[No Title]') AS video_title,
    LOWER(TRIM(video_trending_country::text)) AS video_trending_country,
    COALESCE(LOWER(TRIM(channel_country::text)), 'unknown') AS channel_country,
    COALESCE(TRIM(video_category_id::text), 'Unknown') AS video_category,
    COALESCE(TRIM(video_dimension::text), 'unknown') AS video_dimension,
    COALESCE(TRIM(video_definition::text), 'unknown') AS video_definition,

    -- Target Encoding Preparation: Converts boolean to a clean analytical flag
    CASE
        WHEN LOWER(TRIM(video_licensed_content::text)) IN ('true', '1', 'yes') THEN TRUE
        ELSE FALSE
    END AS is_licensed_content,

    COALESCE(TRIM(video_description::text), 'No description') AS video_description,
    COALESCE(TRIM(video_tags::text), 'No tags') AS video_tags,

    -- Continuous Feature Engineering: Parses duration strings into flat numeric numeric scale
    COALESCE(CAST((REGEXP_MATCH(video_duration::text, '(\d+)H'))[1] AS INTEGER), 0) * 3600 +
    COALESCE(CAST((REGEXP_MATCH(video_duration::text, '(\d+)M'))[1] AS INTEGER), 0) * 60 +
    COALESCE(CAST((REGEXP_MATCH(video_duration::text, '(\d+)S'))[1] AS INTEGER), 0)
        AS video_duration_seconds,

    video_published_at::timestamp AS video_published_at,
    video_trending_date::date AS video_trending_date,
    channel_published_at::timestamp AS channel_published_at,
    upload_hour::integer AS upload_hour,
    upload_day::integer AS upload_day,
    days_to_trend::integer AS days_to_trend,

    GREATEST(COALESCE(video_view_count::bigint, 0), 0) AS video_view_count,
    GREATEST(COALESCE(video_like_count::bigint, 0), 0) AS video_like_count,
    GREATEST(COALESCE(video_comment_count::bigint, 0), 0) AS video_comment_count,
    GREATEST(COALESCE(channel_subscriber_count::bigint, 0), 0) AS channel_subscriber_count,
    GREATEST(COALESCE(channel_video_count::integer, 0), 0) AS channel_video_count,
    GREATEST(COALESCE(channel_view_count::bigint, 0), 0) AS channel_view_count,

    -- Pre-calculated engagement metrics wrapped securely to protect model array calculations
    ROUND(COALESCE(like_view_ratio::numeric, 0.0), 4) AS like_view_ratio,
    ROUND(COALESCE(comment_density::numeric, 0.0), 4) AS comment_density,
    ROUND(COALESCE(subscriber_breakthrough_ratio::numeric, 0.0), 4) AS subscriber_breakthrough_ratio
FROM
    youtube_data_schema.vw_final_modeling_ready vfmr
WHERE
    vfmr.channel_id IS NOT NULL
    AND vfmr.video_id IS NOT NULL;


-- ============================================================================
-- 2. MARKET OPPORTUNITY VIEW (Enhanced for Niche & Competitive Analysis)
-- ============================================================================
-- ML Context: Great for EDA or extracting aggregated domain features (e.g.,
--             mapping average category view metrics back onto your raw training tables).
-- ============================================================================
CREATE OR REPLACE VIEW youtube_data_schema.vw_market_opportunity AS
SELECT
    video_trending_country,
    video_category,
    COUNT(*) AS trending_video_count,
    COUNT(DISTINCT channel_id) AS unique_channels_competing,
    ROUND(AVG(video_view_count)::numeric, 2) AS avg_views,
    ROUND(AVG(like_view_ratio)::numeric, 4) AS avg_like_ratio,
    ROUND(AVG(comment_density)::numeric, 4) AS avg_comment_density,
    ROUND(AVG(video_duration_seconds)::numeric, 2) AS avg_video_duration_secs
FROM youtube_data_schema.vw_base_clean
GROUP BY video_trending_country, video_category;


-- ============================================================================
-- 3. KENYAN VS GLOBAL COMPARISON VIEW (Enhanced for Velocity Context)
-- ============================================================================
-- ML Context: Validates stratification. Used to check if your training data balances
--             geographically before feeding it into country-agnostic algorithms.
-- ============================================================================
CREATE OR REPLACE VIEW youtube_data_schema.vw_kenya_global_comparison AS
SELECT
    CASE
        WHEN LOWER(video_trending_country) IN ('kenya', 'ke') THEN 'Kenya'
        ELSE 'Global'
    END AS market,
    video_category,
    COUNT(*) AS videos,
    SUM(video_view_count)::bigint AS total_market_views,
    ROUND(AVG(video_view_count)::numeric, 2) AS avg_views,
    ROUND(AVG(like_view_ratio)::numeric, 4) AS avg_like_ratio,
    ROUND(AVG(comment_density)::numeric, 4) AS avg_comment_density,
    ROUND(AVG(days_to_trend)::numeric, 2) AS avg_days_to_trend
FROM youtube_data_schema.vw_base_clean
GROUP BY
    CASE WHEN LOWER(video_trending_country) IN ('kenya', 'ke') THEN 'Kenya' ELSE 'Global' END,
    video_category;


-- ============================================================================
-- 4. BREAKTHROUGH VIRALITY VIEW (Enhanced Feature Set for Linear/Tree Models)
-- ============================================================================
-- ML Context: This is your binary/multiclass target data set. By retaining
--             `video_trending_country`, you avoid a critical bug where the view
--             drops valid international rows, which would artificially choke your
--             model's sample size and skew geographic representation.
-- ============================================================================
CREATE OR REPLACE VIEW youtube_data_schema.vw_breakthrough_video AS
WITH ranked_videos AS (
    SELECT *,
        -- Deduplication logic matches your exact primary key grain (Video + Country)
        ROW_NUMBER() OVER(
            PARTITION BY video_id, video_trending_country
            ORDER BY video_view_count DESC
        ) as rn
    FROM youtube_data_schema.vw_base_clean
)
SELECT
    video_id,
    channel_id,
    video_trending_country, -- CRITICAL ML FEATURE: Keeps geographic matrix blocks aligned
    video_title,
    channel_title,
    video_category,
    video_published_at,
    upload_hour,        -- ML FEATURE: Ready for cyclical sine/cosine time transformations
    upload_day,         -- ML FEATURE: Ready for cyclical sine/cosine time transformations
    video_view_count,
    video_like_count,
    video_comment_count,
    channel_subscriber_count,
    channel_video_count,
    subscriber_breakthrough_ratio AS outlier_multiplier,
    like_view_ratio,
    comment_density
FROM ranked_videos
WHERE rn = 1 AND subscriber_breakthrough_ratio >= 5.0;


-- ============================================================================
-- 5. CONTENT DECAY VIEW (Enhanced with Identifiers for Filter-by-Topic Checks)
-- ============================================================================
-- ML Context: Time-to-trend regression target engine. Preserves country and categorical
--             context to map decay over regional algorithmic lifecycles.
-- ============================================================================
CREATE OR REPLACE VIEW youtube_data_schema.vw_content_decay AS
SELECT
    video_id,
    video_trending_country, -- ML FEATURE: Allows regional grouping for time-series splits
    video_title,
    channel_title,
    video_category,
    days_to_trend,     -- ML TARGET VALUE: Perfect target for continuous regression tasks
    video_view_count,
    like_view_ratio,
    comment_density
FROM youtube_data_schema.vw_base_clean;


-- ============================================================================
-- 6. CHANNEL COHORT VIEW (Strict Channel Entity Grain for K-Means)
-- ============================================================================
-- ML Context: UN-SUPERVISED PIPELINE INGESTION ROW GRAIN.
--             This view intentionally collapses everything down to a pure channel primary key.
--             By grouping metrics strictly by channel_id, it is 100% mathematically ready
--             to be loaded directly into a Scikit-Learn K-Means or PCA dimension pipeline
--             to execute creator segmentation profiles without multi-row weight distortions.
-- ============================================================================
CREATE OR REPLACE VIEW youtube_data_schema.vw_channel_features AS
SELECT
    channel_id,                        -- CLUSTERING KEY: The absolute entity row grain
    MAX(channel_title) AS channel_title,
    MAX(channel_subscriber_count) AS channel_subscriber_count,
    MAX(channel_video_count) AS channel_video_count,
    MAX(channel_view_count) AS channel_view_count,
    ROUND(AVG(video_view_count)::numeric, 2) AS avg_views,
    ROUND(AVG(like_view_ratio)::numeric, 4) AS avg_like_ratio,
    ROUND(AVG(comment_density)::numeric, 4) AS avg_comment_density,
    MAX(subscriber_breakthrough_ratio) AS peak_breakthrough_ratio,
    COUNT(*) AS trending_appearances,
    MIN(video_published_at) AS earliest_trending_upload
FROM youtube_data_schema.vw_base_clean
GROUP BY channel_id;


-- ============================================================================
-- 7. NLP FEATURE VIEW (Enhanced with Video Attributes for Metadata Control Flags)
-- ============================================================================
-- ML Context: TEXT MODELING CORPUS (TF-IDF / HuggingFace Transformers / BERT).
--             Preserving `video_trending_country` ensures you don't break textual patterns
--             unique to specific regional naming spaces. Category mapping lets you feed
--             unstructured string arrays directly into multi-class NLP classifiers.
-- ============================================================================
CREATE OR REPLACE VIEW youtube_data_schema.vw_nlp_features AS
WITH ranked_nlp AS (
    SELECT *,
        ROW_NUMBER() OVER(
            PARTITION BY video_id, video_trending_country
            ORDER BY video_view_count DESC
        ) as rn
    FROM youtube_data_schema.vw_base_clean
)
SELECT
    video_id,
    video_trending_country, -- NLP FEATURE: Controls for regional linguistic dialects/slang
    video_title,            -- TEXT CORPUS INPUT
    LENGTH(video_title) AS title_length,
    video_description,      -- TEXT CORPUS INPUT
    video_tags,             -- TEXT CORPUS INPUT
    video_category,
    video_definition,
    is_licensed_content,
    video_view_count,
    like_view_ratio,
    comment_density,
    subscriber_breakthrough_ratio
FROM ranked_nlp
WHERE rn = 1;


-- ============================================================================
-- 8. UPLOAD TIMING VIEW (Enhanced for Heatmaps Across Different Genres)
-- ============================================================================
-- ML Context: Cyclical Time Density Analysis. Preserving regional contexts ensures
--             time stamps remain tied to national time-zones/audience active window peaks.
-- ============================================================================
CREATE OR REPLACE VIEW youtube_data_schema.vw_upload_timing AS
WITH ranked_timing AS (
    SELECT *,
        ROW_NUMBER() OVER(
            PARTITION BY video_id, video_trending_country
            ORDER BY video_view_count DESC
        ) as rn
    FROM youtube_data_schema.vw_base_clean
)
SELECT
    video_id,
    video_trending_country, -- ML FEATURE: Prevents time-zone blending bias across global regions
    video_category,
    upload_hour,            -- FEATURE: Raw structural input hour for temporal modeling
    upload_day,             -- FEATURE: Raw structural input day for temporal modeling
    days_to_trend,
    video_view_count,
    like_view_ratio,
    comment_density
FROM ranked_timing
WHERE rn = 1;


-- ============================================================================
-- 9. TRANSLATION PIPELINE VIEW (Asynchronous Queue)
-- ============================================================================
-- ML Context: Extract-Transform-Load Pipeline Queue. Pulls clean string targets
--             to pipeline directly into external deep learning translation models.
-- ============================================================================
CREATE OR REPLACE VIEW youtube_data_schema.vw_translation_queue AS
SELECT DISTINCT
    video_id,
    video_trending_country,
    video_title,
    video_description,
    channel_title
FROM youtube_data_schema.vw_base_clean
WHERE video_title != '[No Title]';

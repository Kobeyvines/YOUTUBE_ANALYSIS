CREATE TABLE youtube_data_schema.tbl_translation_workspace AS
SELECT DISTINCT
    video_id,
    video_trending_country,
    video_title,
    video_description,
    channel_title,

    NULL::text AS detected_language,
    NULL::text AS translated_title,
    NULL::text AS translated_description,
    NULL::boolean AS translation_complete

FROM youtube_data_schema.vw_base_clean
WHERE video_title <> '[No Title]';

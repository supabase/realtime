SELECT broadcast_storage_enabled_at IS NOT NULL AS enabled FROM realtime.channels WHERE topic = 'news';

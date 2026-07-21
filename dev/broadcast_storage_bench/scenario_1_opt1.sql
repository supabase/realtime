SELECT broadcast_storage_enabled_at FROM realtime.channels WHERE topic = 'news';
INSERT INTO realtime.messages_opt1 (topic, extension, payload, event, private) VALUES ('news', 'broadcast', '{"msg": "bench"}', 'event', true);

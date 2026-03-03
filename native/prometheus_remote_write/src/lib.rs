mod proto;

use std::collections::BTreeMap;

use chrono::DateTime;
use prometheus_parse::{Sample, Scrape, Value};
use prost::Message;
use rustler::{Binary, Encoder, Env, OwnedBinary, Term};

mod atoms {
    rustler::atoms! { ok, error }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode(env: Env<'_>, text: String, timestamp_ms: i64) -> Term<'_> {
    match do_encode(text, timestamp_ms) {
        Ok(bytes) => {
            let Some(mut owned) = OwnedBinary::new(bytes.len()) else {
                return (atoms::error(), "allocation failed").encode(env);
            };
            owned.as_mut_slice().copy_from_slice(&bytes);
            (atoms::ok(), Binary::from_owned(owned, env)).encode(env)
        }
        Err(e) => (atoms::error(), e).encode(env),
    }
}

fn scalar_value(value: &Value) -> Option<f64> {
    match value {
        Value::Counter(v) | Value::Gauge(v) | Value::Untyped(v) => Some(*v),
        _ => None,
    }
}

fn sorted_labels(sample: &Sample) -> Vec<(String, String)> {
    let mut labels: Vec<(String, String)> = sample.labels.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    labels.sort_unstable_by(|a, b| a.0.cmp(&b.0));
    labels
}

fn series_key(metric: &str, labels: &[(String, String)]) -> String {
    std::iter::once(metric)
        .chain(labels.iter().flat_map(|(k, v)| [k.as_str(), v.as_str()]))
        .collect::<Vec<_>>()
        .join("\x00")
}

fn build_time_series(metric: &str, labels: &[(String, String)]) -> proto::TimeSeries {
    let mut proto_labels = Vec::with_capacity(labels.len() + 1);
    proto_labels.push(proto::Label {
        name: "__name__".into(),
        value: metric.to_string(),
    });
    proto_labels.extend(labels.iter().map(|(k, v)| proto::Label {
        name: k.clone(),
        value: v.clone(),
    }));
    proto::TimeSeries {
        labels: proto_labels,
        samples: Vec::new(),
    }
}

fn accumulate_sample(
    mut map: BTreeMap<String, proto::TimeSeries>,
    sample: Sample,
) -> BTreeMap<String, proto::TimeSeries> {
    let Some(value) = scalar_value(&sample.value) else {
        return map;
    };

    let labels = sorted_labels(&sample);
    let key = series_key(&sample.metric, &labels);
    let ts_ms = sample.timestamp.timestamp_millis();

    let ts = map
        .entry(key)
        .or_insert_with(|| build_time_series(&sample.metric, &labels));

    ts.samples.push(proto::Sample {
        value,
        timestamp: ts_ms,
    });

    map
}

fn do_encode(text: String, timestamp_ms: i64) -> Result<Vec<u8>, String> {
    let default_time =
        DateTime::from_timestamp_millis(timestamp_ms).ok_or_else(|| format!("invalid timestamp: {timestamp_ms}"))?;

    let lines = text.lines().map(|s| Ok(s.to_string()));
    let scrape = Scrape::parse_at(lines, default_time).map_err(|e| format!("parse error: {e}"))?;
    let series_map = scrape.samples.into_iter().fold(BTreeMap::new(), accumulate_sample);

    let bytes = proto::WriteRequest {
        timeseries: series_map.into_values().collect(),
    }
    .encode_to_vec();

    snap::raw::Encoder::new()
        .compress_vec(&bytes)
        .map_err(|e| format!("snappy compression failed: {e}"))
}

rustler::init!("Elixir.Realtime.PrometheusRemoteWrite");

#[cfg(test)]
mod tests {
    use prost::Message;

    use super::*;

    fn decode(bytes: &[u8]) -> proto::WriteRequest {
        let decompressed = snap::raw::Decoder::new().decompress_vec(bytes).unwrap();
        proto::WriteRequest::decode(decompressed.as_slice()).unwrap()
    }

    #[test]
    fn encodes_gauge_metric() {
        let text = "# TYPE my_gauge gauge\nmy_gauge 42.0 1700000000000\n";
        let bytes = do_encode(text.into(), 1_700_000_000_000).unwrap();
        let req = decode(&bytes);

        assert_eq!(req.timeseries.len(), 1);
        let ts = &req.timeseries[0];
        assert_eq!(ts.samples.len(), 1);
        assert_eq!(ts.samples[0].value, 42.0);
        assert_eq!(ts.samples[0].timestamp, 1_700_000_000_000);
        assert!(ts.labels.iter().any(|l| l.name == "__name__" && l.value == "my_gauge"));
    }

    #[test]
    fn encodes_counter_metric() {
        let text = "# TYPE my_counter counter\nmy_counter 1.0 1700000000000\n";
        let bytes = do_encode(text.into(), 1_700_000_000_000).unwrap();
        let req = decode(&bytes);

        assert_eq!(req.timeseries.len(), 1);
        assert_eq!(req.timeseries[0].samples[0].value, 1.0);
    }

    #[test]
    fn groups_multiple_samples_into_one_time_series() {
        let text = "my_gauge{env=\"prod\"} 1.0 1700000000000\nmy_gauge{env=\"prod\"} 2.0 1700000000001\n";
        let bytes = do_encode(text.into(), 1_700_000_000_000).unwrap();
        let req = decode(&bytes);

        assert_eq!(req.timeseries.len(), 1);
        assert_eq!(req.timeseries[0].samples.len(), 2);
    }

    #[test]
    fn separates_different_label_sets_into_distinct_time_series() {
        let text = "my_gauge{env=\"prod\"} 1.0 1700000000000\nmy_gauge{env=\"dev\"} 2.0 1700000000000\n";
        let bytes = do_encode(text.into(), 1_700_000_000_000).unwrap();
        let req = decode(&bytes);

        assert_eq!(req.timeseries.len(), 2);
    }

    #[test]
    fn labels_are_sorted_and_name_label_is_first() {
        let text = "my_gauge{z=\"last\",a=\"first\"} 1.0 1700000000000\n";
        let bytes = do_encode(text.into(), 1_700_000_000_000).unwrap();
        let req = decode(&bytes);

        let labels = &req.timeseries[0].labels;
        assert_eq!(labels[0].name, "__name__");
        assert_eq!(labels[1].name, "a");
        assert_eq!(labels[2].name, "z");
    }

    #[test]
    fn skips_histogram_and_summary_samples() {
        let text = "# TYPE my_hist histogram\nmy_hist_bucket{le=\"0.1\"} 1 1700000000000\n";
        let bytes = do_encode(text.into(), 1_700_000_000_000).unwrap();
        let req = decode(&bytes);

        assert_eq!(req.timeseries.len(), 0);
    }

    #[test]
    fn empty_input_produces_empty_write_request() {
        let bytes = do_encode("".into(), 1_700_000_000_000).unwrap();
        let req = decode(&bytes);

        assert_eq!(req.timeseries.len(), 0);
    }

    #[test]
    fn uses_fallback_timestamp_when_metric_has_none() {
        let text = "my_gauge 99.0\n";
        let bytes = do_encode(text.into(), 1_700_000_000_000).unwrap();
        let req = decode(&bytes);

        assert_eq!(req.timeseries[0].samples[0].timestamp, 1_700_000_000_000);
    }

    #[test]
    fn invalid_timestamp_returns_error() {
        let result = do_encode("my_gauge 1.0\n".into(), i64::MAX);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("invalid timestamp"));
    }
}

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

fn push_series(
    map: &mut BTreeMap<String, proto::TimeSeries>,
    metric: &str,
    labels: Vec<(String, String)>,
    value: f64,
    ts_ms: i64,
) {
    let key = series_key(metric, &labels);
    let ts = map.entry(key).or_insert_with(|| build_time_series(metric, &labels));
    ts.samples.push(proto::Sample {
        value,
        timestamp: ts_ms,
    });
}

fn le_label(less_than: f64) -> String {
    if less_than == f64::INFINITY {
        "+Inf".to_string()
    } else {
        less_than.to_string()
    }
}

fn accumulate_sample(
    mut map: BTreeMap<String, proto::TimeSeries>,
    sample: Sample,
) -> BTreeMap<String, proto::TimeSeries> {
    let Sample {
        metric,
        value,
        labels: _,
        timestamp,
    } = &sample;
    let ts_ms = timestamp.timestamp_millis();

    match value {
        Value::Histogram(buckets) => {
            let base_labels = sorted_labels(&sample);
            let bucket_metric = format!("{}_bucket", metric);
            for bucket in buckets {
                let mut lbls = base_labels.clone();
                lbls.push(("le".to_string(), le_label(bucket.less_than)));
                lbls.sort_unstable_by(|a, b| a.0.cmp(&b.0));
                push_series(&mut map, &bucket_metric, lbls, bucket.count, ts_ms);
            }
        }
        Value::Summary(quantiles) => {
            let base_labels = sorted_labels(&sample);
            for q in quantiles {
                let mut lbls = base_labels.clone();
                lbls.push(("quantile".to_string(), q.quantile.to_string()));
                lbls.sort_unstable_by(|a, b| a.0.cmp(&b.0));
                push_series(&mut map, metric, lbls, q.count, ts_ms);
            }
        }
        v => {
            let Some(scalar) = scalar_value(v) else { return map };
            let labels = sorted_labels(&sample);
            push_series(&mut map, metric, labels, scalar, ts_ms);
        }
    }

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

mod atoms_decode {
    rustler::atoms! { name, labels, samples, value, timestamp }
}

fn do_decode(bytes: &[u8]) -> Result<proto::WriteRequest, String> {
    let decomp = snap::raw::Decoder::new()
        .decompress_vec(bytes)
        .map_err(|e| format!("snappy decompress failed: {e}"))?;
    proto::WriteRequest::decode(decomp.as_slice()).map_err(|e| format!("protobuf decode failed: {e}"))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decode<'a>(env: Env<'a>, bytes: Binary<'a>) -> Term<'a> {
    let req = match do_decode(bytes.as_slice()) {
        Ok(r) => r,
        Err(e) => return (atoms::error(), e).encode(env),
    };

    let series: Vec<Term<'_>> = req
        .timeseries
        .into_iter()
        .map(|ts| {
            let name = ts
                .labels
                .iter()
                .find(|l| l.name == "__name__")
                .map(|l| l.value.as_str())
                .unwrap_or("")
                .encode(env);

            let labels: Vec<Term<'_>> = ts
                .labels
                .iter()
                .filter(|l| l.name != "__name__")
                .map(|l| {
                    rustler::types::map::map_new(env)
                        .map_put(l.name.as_str().encode(env), l.value.as_str().encode(env))
                        .unwrap()
                })
                .collect();

            let samples: Vec<Term<'_>> = ts
                .samples
                .iter()
                .map(|s| {
                    rustler::types::map::map_new(env)
                        .map_put(
                            atoms_decode::value().encode(env),
                            rustler::Encoder::encode(&s.value, env),
                        )
                        .unwrap()
                        .map_put(
                            atoms_decode::timestamp().encode(env),
                            rustler::Encoder::encode(&s.timestamp, env),
                        )
                        .unwrap()
                })
                .collect();

            rustler::types::map::map_new(env)
                .map_put(atoms_decode::name().encode(env), name)
                .unwrap()
                .map_put(atoms_decode::labels().encode(env), labels.encode(env))
                .unwrap()
                .map_put(atoms_decode::samples().encode(env), samples.encode(env))
                .unwrap()
        })
        .collect();

    (atoms::ok(), series.encode(env)).encode(env)
}

rustler::init!("Elixir.Realtime.PrometheusRemoteWrite");

#[cfg(test)]
mod tests {
    use super::*;

    fn encode_and_decode(text: &str) -> proto::WriteRequest {
        let bytes = do_encode(text.into(), 1_700_000_000_000).unwrap();
        do_decode(&bytes).unwrap()
    }

    #[test]
    fn encodes_gauge_metric() {
        let text = "# TYPE my_gauge gauge\nmy_gauge 42.0 1700000000000\n";
        let req = encode_and_decode(text);

        assert_eq!(req.timeseries.len(), 1);
        let ts = &req.timeseries[0];
        assert_eq!(ts.samples.len(), 1);
        assert_eq!(ts.samples[0].value, 42.0);
        assert_eq!(ts.samples[0].timestamp, 1_700_000_000_000);
        assert!(ts.labels.iter().any(|l| l.name == "__name__" && l.value == "my_gauge"));
    }

    #[test]
    fn encodes_counter_metric() {
        let req = encode_and_decode("# TYPE my_counter counter\nmy_counter 1.0 1700000000000\n");
        assert_eq!(req.timeseries.len(), 1);
        assert_eq!(req.timeseries[0].samples[0].value, 1.0);
    }

    #[test]
    fn groups_multiple_samples_into_one_time_series() {
        let req =
            encode_and_decode("my_gauge{env=\"prod\"} 1.0 1700000000000\nmy_gauge{env=\"prod\"} 2.0 1700000000001\n");
        assert_eq!(req.timeseries.len(), 1);
        assert_eq!(req.timeseries[0].samples.len(), 2);
    }

    #[test]
    fn separates_different_label_sets_into_distinct_time_series() {
        let req =
            encode_and_decode("my_gauge{env=\"prod\"} 1.0 1700000000000\nmy_gauge{env=\"dev\"} 2.0 1700000000000\n");
        assert_eq!(req.timeseries.len(), 2);
    }

    #[test]
    fn labels_are_sorted_and_name_label_is_first() {
        let req = encode_and_decode("my_gauge{z=\"last\",a=\"first\"} 1.0 1700000000000\n");
        let labels = &req.timeseries[0].labels;
        assert_eq!(labels[0].name, "__name__");
        assert_eq!(labels[1].name, "a");
        assert_eq!(labels[2].name, "z");
    }

    #[test]
    fn encodes_histogram_buckets_with_le_label() {
        let req = encode_and_decode("# TYPE my_hist histogram\nmy_hist_bucket{le=\"0.1\"} 1 1700000000000\nmy_hist_bucket{le=\"+Inf\"} 3 1700000000000\n");

        assert_eq!(req.timeseries.len(), 2);
        let has_bucket = |le: &str| {
            req.timeseries.iter().any(|ts| {
                ts.labels
                    .iter()
                    .any(|l| l.name == "__name__" && l.value == "my_hist_bucket")
                    && ts.labels.iter().any(|l| l.name == "le" && l.value == le)
            })
        };
        assert!(has_bucket("0.1"));
        assert!(has_bucket("+Inf"));
    }

    #[test]
    fn encodes_histogram_sum_and_count_as_untyped() {
        let req = encode_and_decode("# TYPE my_hist histogram\nmy_hist_bucket{le=\"+Inf\"} 3 1700000000000\nmy_hist_sum 12.5 1700000000000\nmy_hist_count 3 1700000000000\n");

        let has_name = |name: &str| {
            req.timeseries
                .iter()
                .any(|ts| ts.labels.iter().any(|l| l.name == "__name__" && l.value == name))
        };
        assert!(has_name("my_hist_sum"));
        assert!(has_name("my_hist_count"));
    }

    #[test]
    fn encodes_summary_quantiles_with_quantile_label() {
        let req = encode_and_decode("# TYPE my_summary summary\nmy_summary{quantile=\"0.5\"} 10 1700000000000\nmy_summary{quantile=\"0.99\"} 50 1700000000000\n");

        assert_eq!(req.timeseries.len(), 2);
        let has_quantile = |q: &str| {
            req.timeseries.iter().any(|ts| {
                ts.labels
                    .iter()
                    .any(|l| l.name == "__name__" && l.value == "my_summary")
                    && ts.labels.iter().any(|l| l.name == "quantile" && l.value == q)
            })
        };
        assert!(has_quantile("0.5"));
        assert!(has_quantile("0.99"));
    }

    #[test]
    fn empty_input_produces_empty_write_request() {
        let req = encode_and_decode("");
        assert_eq!(req.timeseries.len(), 0);
    }

    #[test]
    fn uses_fallback_timestamp_when_metric_has_none() {
        let req = encode_and_decode("my_gauge 99.0\n");
        assert_eq!(req.timeseries[0].samples[0].timestamp, 1_700_000_000_000);
    }

    #[test]
    fn invalid_timestamp_returns_error() {
        let result = do_encode("my_gauge 1.0\n".into(), i64::MAX);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("invalid timestamp"));
    }

    // do_decode tests

    #[test]
    fn decode_roundtrips_gauge_name_labels_and_sample() {
        let bytes = do_encode(
            "# TYPE rtt gauge\nrtt{region=\"eu\"} 1.5 1700000000000\n".into(),
            1_700_000_000_000,
        )
        .unwrap();
        let req = do_decode(&bytes).unwrap();

        assert_eq!(req.timeseries.len(), 1);
        let ts = &req.timeseries[0];
        assert!(ts.labels.iter().any(|l| l.name == "__name__" && l.value == "rtt"));
        assert!(ts.labels.iter().any(|l| l.name == "region" && l.value == "eu"));
        assert_eq!(ts.samples[0].value, 1.5);
        assert_eq!(ts.samples[0].timestamp, 1_700_000_000_000);
    }

    #[test]
    fn decode_roundtrips_histogram_bucket_values() {
        let text = "# TYPE http_req histogram\n\
                    http_req_bucket{le=\"0.05\"} 10 1700000000000\n\
                    http_req_bucket{le=\"0.5\"} 90 1700000000000\n\
                    http_req_bucket{le=\"+Inf\"} 100 1700000000000\n\
                    http_req_sum 42.0 1700000000000\n\
                    http_req_count 100 1700000000000\n";
        let bytes = do_encode(text.into(), 1_700_000_000_000).unwrap();
        let req = do_decode(&bytes).unwrap();

        let bucket = |le: &str| -> f64 {
            req.timeseries
                .iter()
                .find(|ts| {
                    ts.labels
                        .iter()
                        .any(|l| l.name == "__name__" && l.value == "http_req_bucket")
                        && ts.labels.iter().any(|l| l.name == "le" && l.value == le)
                })
                .and_then(|ts| ts.samples.first())
                .map(|s| s.value)
                .unwrap_or(f64::NAN)
        };
        assert_eq!(bucket("0.05"), 10.0);
        assert_eq!(bucket("0.5"), 90.0);
        assert_eq!(bucket("+Inf"), 100.0);

        let sum = req
            .timeseries
            .iter()
            .find(|ts| {
                ts.labels
                    .iter()
                    .any(|l| l.name == "__name__" && l.value == "http_req_sum")
            })
            .and_then(|ts| ts.samples.first())
            .map(|s| s.value)
            .unwrap();
        assert_eq!(sum, 42.0);
    }

    #[test]
    fn decode_roundtrips_summary_quantile_values() {
        let text = "# TYPE latency summary\n\
                    latency{quantile=\"0.5\"} 200 1700000000000\n\
                    latency{quantile=\"0.99\"} 800 1700000000000\n\
                    latency_sum 50000 1700000000000\n\
                    latency_count 300 1700000000000\n";
        let bytes = do_encode(text.into(), 1_700_000_000_000).unwrap();
        let req = do_decode(&bytes).unwrap();

        let quantile = |q: &str| -> f64 {
            req.timeseries
                .iter()
                .find(|ts| {
                    ts.labels.iter().any(|l| l.name == "__name__" && l.value == "latency")
                        && ts.labels.iter().any(|l| l.name == "quantile" && l.value == q)
                })
                .and_then(|ts| ts.samples.first())
                .map(|s| s.value)
                .unwrap_or(f64::NAN)
        };
        assert_eq!(quantile("0.5"), 200.0);
        assert_eq!(quantile("0.99"), 800.0);
    }

    #[test]
    fn decode_error_on_invalid_snappy() {
        let err = do_decode(b"not snappy compressed data at all").unwrap_err();
        assert!(err.contains("snappy decompress failed"), "got: {err}");
    }

    #[test]
    fn decode_error_on_valid_snappy_but_invalid_protobuf() {
        let garbage = snap::raw::Encoder::new()
            .compress_vec(b"this is not a protobuf message")
            .unwrap();
        let err = do_decode(&garbage).unwrap_err();
        assert!(err.contains("protobuf decode failed"), "got: {err}");
    }

    #[test]
    fn decode_empty_write_request_roundtrips() {
        let bytes = do_encode("".into(), 1_700_000_000_000).unwrap();
        let req = do_decode(&bytes).unwrap();
        assert_eq!(req.timeseries.len(), 0);
    }
}

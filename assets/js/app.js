import "../css/app.css";
import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";
import { createClient } from "@supabase/supabase-js";

const Hooks = {};

function logEvent(hook, category, event, payload, latencyMs = null) {
  hook.pushEventTo("#event_log", "log_event", {
    category,
    event,
    payload,
    received_at: new Date().toISOString(),
    latency_ms: latencyMs,
  });
}

Hooks.payload = {
  initRealtime(connection) {
    const { channel: channelName, host, log_level, token, schema, table, filter, bearer, enable_presence, enable_db_changes, private_channel } =
      connection;

    if (this.channel) this.channel.unsubscribe();
    if (this.realtimeSocket) this.realtimeSocket.realtime.disconnect();

    this.realtimeSocket = createClient(host, token, {
      realtime: {
        params: { log_level },
        heartbeatCallback: (status, latency) =>
          this.pushEvent("transport_status", { status, latency_ms: latency ?? null }),
        logger: (kind, msg, data) => logEvent(this, kind, msg, { data }),
      },
    });

    if (bearer) this.realtimeSocket.realtime.setAuth(bearer);

    this.channel = this.realtimeSocket.channel(channelName, {
      config: { broadcast: { self: true }, private: private_channel === "true" },
    });

    this.channel.on("system", {}, (payload) => {
      if (payload.extension === "postgres_changes") {
        if (payload.status === "ok") this.pushEvent("postgres_subscribed", { schema, table, filter });
        else if (payload.status === "error") this.pushEvent("postgres_error", { reason: payload.message ?? "unknown error" });
      }
      logEvent(this, "system", payload.extension ?? "system", payload);
    });

    this.channel.on("broadcast", { event: "*" }, (payload) => {
      logEvent(this, "broadcast", payload.event ?? "broadcast", payload);
    });

    if (enable_presence === "true") {
      this.channel.on("presence", { event: "sync" }, () => {
        this.pushEvent("presence_synced", { count: Object.keys(this.channel.presenceState()).length });
      });

      this.channel.on("presence", { event: "*" }, (payload) => {
        logEvent(this, "presence", payload.event ?? "presence", payload);
      });
    }

    if (enable_db_changes === "true") {
      const opts = { event: "*", schema, table, ...(filter ? { filter } : {}) };

      this.channel.on("postgres_changes", opts, (payload) => {
        const latency = performance.now() + performance.timeOrigin - Date.parse(payload.commit_timestamp);
        logEvent(this, "postgres", payload.eventType ?? "postgres_changes", payload, latency);
      });
    }

    this.pushEvent("channel_status", { status: "joining", reason: null });

    const statusMap = { TIMED_OUT: "timed_out", CLOSED: "closed", CHANNEL_ERROR: "errored" };

    this.channel.subscribe(async (status, error) => {
      if (status !== "SUBSCRIBED") {
        this.pushEvent("channel_status", { status: statusMap[status] ?? "errored", reason: error ? String(error) : status });
        return;
      }

      this.pushEvent("channel_status", { status: "joined", host, reason: null });
      localStorage.setItem("token", token);
      localStorage.setItem("bearer", bearer ?? "");

      if (enable_presence === "true") {
        await this.channel.track({ name: "user_" + Math.floor(Math.random() * 100), t: performance.now() });
      }
    });
  },

  sendRealtime(event, payload) {
    this.channel.send({ type: "broadcast", event, payload });
  },

  disconnectRealtime() {
    this.channel.unsubscribe();
    this.pushEvent("channel_status", { status: "closed", reason: null });
    this.pushEvent("transport_status", { status: "disconnected", latency_ms: null });
  },

  clearLocalStorage() {
    localStorage.clear();
  },

  mounted() {
    this.pushEventTo("#conn_form", "local_storage", {
      token: localStorage.getItem("token"),
      bearer: localStorage.getItem("bearer"),
    });

    this.handleEvent("connect", ({ connection }) => this.initRealtime(connection));
    this.handleEvent("send_message", ({ message }) => this.sendRealtime(message.event, message.payload));
    this.handleEvent("disconnect", () => this.disconnectRealtime());
    this.handleEvent("clear_local_storage", () => this.clearLocalStorage());
  },
};

Hooks.copyToClipboard = {
  mounted() {
    this.label = this.el.querySelector("#share-button-label");
    this.originalLabel = this.label.textContent;

    this.el.addEventListener("click", () => {
      navigator.clipboard.writeText(this.el.dataset.url).then(() => {
        clearTimeout(this.resetTimer);
        this.label.textContent = "Copied URL";
        this.resetTimer = setTimeout(() => (this.label.textContent = this.originalLabel), 1500);
      });
    });
  },
};

Hooks.themeToggle = {
  mounted() {
    this.el.addEventListener("click", () => {
      const isDark = document.documentElement.classList.toggle("dark");
      localStorage.setItem("theme", isDark ? "dark" : "light");
    });
  },
};

// Keeps a <details> panel's open/closed state across LiveView DOM patches (which otherwise reset
// native `open` every time the event log streams a new row).
Hooks.detailsKeepState = {
  mounted() {
    this.open = this.el.open;
    this.el.addEventListener("toggle", () => (this.open = this.el.open));
  },
  updated() {
    this.el.open = this.open;
  },
};

// Newest rows are prepended at the top, so keep the view pinned to the top — releasing the pin
// once the user scrolls down to read older entries.
Hooks.autoscroll = {
  mounted() {
    this.pinned = true;
    this.el.addEventListener("scroll", () => {
      this.pinned = this.el.scrollTop < 40;
    });
  },

  updated() {
    if (this.pinned) this.el.scrollTop = 0;
  },
};

Hooks.exportLog = {
  mounted() {
    this.el.addEventListener("click", () => {
      const rows = document.querySelectorAll("#event_log_rows > tr:not(.hidden)");
      const lines = Array.from(rows).map((row) =>
        JSON.stringify({
          category: row.dataset.category,
          event: row.dataset.event,
          received_at: row.dataset.receivedAt,
          latency_ms: row.dataset.latencyMs ? Number(row.dataset.latencyMs) : null,
          payload: JSON.parse(row.dataset.payload),
        })
      );

      const blob = new Blob([lines.join("\n")], { type: "application/x-ndjson" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `realtime-event-log-${new Date().toISOString()}.ndjson`;
      a.click();
      URL.revokeObjectURL(url);
    });
  },
};

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: { _csrf_token: csrfToken },
});

topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", () => topbar.show());
window.addEventListener("phx:page-loading-stop", () => topbar.hide());

liveSocket.connect();

window.liveSocket = liveSocket;

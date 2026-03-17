defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000
  @snapshot_stale_seconds 45
  @session_waiting_seconds 45
  @session_stalled_seconds 180

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("refresh_runtime", _params, socket) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        {:noreply,
         socket
         |> put_flash(:info, refresh_runtime_message(payload))
         |> assign(:payload, load_payload())
         |> assign(:now, DateTime.utc_now())}

      {:error, :unavailable} ->
        {:noreply,
         socket
         |> put_flash(:error, "Runtime refresh is unavailable because the orchestrator is offline.")
         |> assign(:payload, load_payload())
         |> assign(:now, DateTime.utc_now())}
    end
  end

  @impl true
  def handle_event("reconcile_history", _params, socket) do
    case Presenter.reconcile_history_payload(orchestrator()) do
      {:ok, %{success: true} = payload} ->
        {:noreply,
         socket
         |> put_flash(:info, reconcile_history_message(payload))
         |> assign(:payload, load_payload())
         |> assign(:now, DateTime.utc_now())}

      {:ok, payload} ->
        {:noreply,
         socket
         |> put_flash(:error, reconcile_history_error(payload))
         |> assign(:payload, load_payload())
         |> assign(:now, DateTime.utc_now())}

      {:error, :unavailable} ->
        {:noreply,
         socket
         |> put_flash(:error, "History reconciliation is unavailable because the orchestrator is offline.")
         |> assign(:payload, load_payload())
         |> assign(:now, DateTime.utc_now())}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="hero-sidecar">
            <div class="section-actions hero-actions">
              <button
                type="button"
                class="secondary"
                phx-click="refresh_runtime"
                phx-disable-with="Refreshing..."
              >
                Refresh runtime
              </button>
              <button
                type="button"
                class="secondary"
                phx-click="reconcile_history"
                phx-disable-with="Reconciling..."
              >
                Reconcile history
              </button>
            </div>

            <div class="status-stack">
              <span class="status-badge status-badge-live">
                <span class="status-badge-dot"></span>
                Socket live
              </span>
              <span class="status-badge status-badge-offline">
                <span class="status-badge-dot"></span>
                Socket offline
              </span>
              <span class={runtime_health_badge_class(@payload, @now)}>
                <span class="status-badge-dot"></span>
                <%= runtime_health_label(@payload, @now) %>
              </span>
              <p class="status-detail">
                Snapshot age <span class="mono numeric"><%= format_age(snapshot_age_seconds(@payload, @now)) %></span>
              </p>
            </div>
          </div>
        </div>
      </header>

      <div :if={flash_message(@flash, :info) || flash_message(@flash, :error)} class="flash-stack">
        <p :if={flash_message(@flash, :info)} class="flash-banner flash-banner-info">
          <%= flash_message(@flash, :info) %>
        </p>
        <p :if={flash_message(@flash, :error)} class="flash-banner flash-banner-error">
          <%= flash_message(@flash, :error) %>
        </p>
      </div>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Process uptime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(process_uptime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Wall-clock time since this Symphony runtime started.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Snapshot age</p>
            <p class="metric-value numeric"><%= format_age(snapshot_age_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Time since the dashboard payload was last refreshed.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Stalled</p>
            <p class="metric-value numeric"><%= length(stalled_running_entries(@payload, @now)) %></p>
            <p class="metric-detail">Running sessions without a fresh Codex event for at least 3 minutes.</p>
          </article>
        </section>

        <section class={operator_banner_class(@payload, @now)}>
          <div class="operator-banner-copy">
            <p class="operator-banner-label">Operator summary</p>
            <h2 class="operator-banner-title"><%= operator_banner_title(@payload, @now) %></h2>
            <p class="operator-banner-body"><%= operator_banner_body(@payload, @now) %></p>
          </div>
          <div class="operator-banner-metrics">
            <div class="operator-banner-stat">
              <span class="operator-banner-stat-label">Process</span>
              <span class="operator-banner-stat-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %> tokens</span>
            </div>
            <div class="operator-banner-stat">
              <span class="operator-banner-stat-label">History</span>
              <span class="operator-banner-stat-value numeric"><%= format_int(history_value(@payload, [:lifetime_codex_totals, :total_tokens])) %> tokens</span>
            </div>
          </div>
        </section>

        <section :if={show_attention_panel?(@payload, @now)} class="section-card section-card-attention">
          <div class="section-header">
            <div>
              <h2 class="section-title">Needs attention</h2>
              <p class="section-copy">Operational signals that usually need an operator decision.</p>
            </div>
          </div>

          <div class="attention-grid">
            <article :if={snapshot_stale?(@payload, @now)} class="attention-item attention-item-warning">
              <h3>Snapshot is stale</h3>
              <p>
                The dashboard payload is <span class="mono numeric"><%= format_age(snapshot_age_seconds(@payload, @now)) %></span> old.
                LiveView is still connected, but Symphony has not published a fresh snapshot recently.
              </p>
            </article>

            <article :if={@payload.counts.retrying > 0} class="attention-item attention-item-warning">
              <h3>Retry pressure</h3>
              <p>
                <span class="mono numeric"><%= @payload.counts.retrying %></span> issues are waiting in the retry queue.
              </p>
            </article>

            <article
              :for={entry <- stalled_running_entries(@payload, @now)}
              class="attention-item attention-item-danger"
            >
              <h3><%= entry.issue_identifier %> looks stalled</h3>
              <p>
                No fresh Codex event for <span class="mono numeric"><%= format_age(session_activity_age_seconds(entry, @now)) %></span>.
              </p>
            </article>
          </div>
        </section>

        <div class="live-grid">
          <div class="live-main">
            <section class="section-card">
              <div class="section-header">
                <div>
                  <h2 class="section-title">Running sessions</h2>
                  <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
                </div>
              </div>

              <%= if @payload.running == [] do %>
                <p class="empty-state"><%= running_empty_state(@payload, @now) %></p>
              <% else %>
                <div class="table-wrap desktop-table-wrap">
                  <table class="data-table data-table-running">
                    <colgroup>
                      <col style="width: 12rem;" />
                      <col style="width: 8rem;" />
                      <col style="width: 7.5rem;" />
                      <col style="width: 8.5rem;" />
                      <col />
                      <col style="width: 10rem;" />
                    </colgroup>
                    <thead>
                      <tr>
                        <th>Issue</th>
                        <th>State</th>
                        <th>Activity</th>
                        <th>Session</th>
                        <th>Runtime / turns</th>
                        <th>Codex update</th>
                        <th>Tokens</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={entry <- @payload.running}>
                        <td>
                          <div class="issue-stack">
                            <span class="issue-id"><%= entry.issue_identifier %></span>
                            <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                          </div>
                        </td>
                        <td>
                          <span class={state_badge_class(entry.state)}>
                            <%= entry.state %>
                          </span>
                        </td>
                        <td>
                          <div class="detail-stack">
                            <span class={session_health_badge_class(entry, @now)}>
                              <%= session_health_label(entry, @now) %>
                            </span>
                            <span class="muted">
                              <%= session_health_detail(entry, @now) %>
                            </span>
                          </div>
                        </td>
                        <td>
                          <div class="session-stack">
                            <%= if entry.session_id do %>
                              <button
                                type="button"
                                class="subtle-button"
                                data-label="Copy ID"
                                data-copy={entry.session_id}
                                onclick="return window.copyDashboardText(this);"
                              >
                                Copy ID
                              </button>
                            <% else %>
                              <span class="muted">n/a</span>
                            <% end %>
                          </div>
                        </td>
                        <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                        <td>
                          <div class="detail-stack">
                            <span
                              class="event-text"
                              title={entry.last_message || to_string(entry.last_event || "n/a")}
                            ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                            <span class="muted event-meta">
                              <%= entry.last_event || "n/a" %>
                              <%= if entry.last_event_at do %>
                                · <span class="mono numeric"><%= entry.last_event_at %></span>
                              <% end %>
                            </span>
                          </div>
                        </td>
                        <td>
                          <div class="token-stack numeric">
                            <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                            <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                          </div>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>

                <div class="mobile-list">
                  <article :for={entry <- @payload.running} class="mobile-card">
                    <div class="mobile-card-header">
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>

                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </div>

                    <div class="mobile-detail-grid">
                      <div class="mobile-detail-row">
                        <span class="mobile-detail-label">Activity</span>
                        <div class="mobile-detail-value mobile-inline-stack">
                          <span class={session_health_badge_class(entry, @now)}>
                            <%= session_health_label(entry, @now) %>
                          </span>
                          <span class="muted"><%= session_health_detail(entry, @now) %></span>
                        </div>
                      </div>

                      <div class="mobile-detail-row">
                        <span class="mobile-detail-label">Session</span>
                        <div class="mobile-detail-value">
                          <%= if entry.session_id do %>
                            <button
                              type="button"
                              class="subtle-button"
                              data-label="Copy ID"
                              data-copy={entry.session_id}
                              onclick="return window.copyDashboardText(this);"
                            >
                              Copy ID
                            </button>
                          <% else %>
                            <span class="muted">n/a</span>
                          <% end %>
                        </div>
                      </div>

                      <div class="mobile-detail-row">
                        <span class="mobile-detail-label">Runtime and turns</span>
                        <span class="mobile-detail-value numeric">
                          <%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %>
                        </span>
                      </div>

                      <div class="mobile-detail-row">
                        <span class="mobile-detail-label">Last update</span>
                        <div class="mobile-detail-value mobile-inline-stack">
                          <span class="mobile-event-text">
                            <%= entry.last_message || to_string(entry.last_event || "n/a") %>
                          </span>
                          <span class="muted">
                            <%= entry.last_event || "n/a" %>
                            <%= if entry.last_event_at do %>
                              · <span class="mono numeric"><%= entry.last_event_at %></span>
                            <% end %>
                          </span>
                        </div>
                      </div>

                      <div class="mobile-detail-row">
                        <span class="mobile-detail-label">Total tokens</span>
                        <div class="mobile-detail-value mobile-inline-stack numeric">
                          <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                          <span class="muted">
                            In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %>
                          </span>
                        </div>
                      </div>
                    </div>
                  </article>
                </div>
              <% end %>
            </section>

            <section class="section-card">
              <div class="section-header">
                <div>
                  <h2 class="section-title">Retry queue</h2>
                  <p class="section-copy">Issues waiting for the next retry window.</p>
                </div>
              </div>

              <%= if @payload.retrying == [] do %>
                <p class="empty-state"><%= retry_empty_state(@payload, @now) %></p>
              <% else %>
                <div class="table-wrap desktop-table-wrap">
                  <table class="data-table" style="min-width: 680px;">
                    <thead>
                      <tr>
                        <th>Issue</th>
                        <th>Attempt</th>
                        <th>Due at</th>
                        <th>Error</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={entry <- @payload.retrying}>
                        <td>
                          <div class="issue-stack">
                            <span class="issue-id"><%= entry.issue_identifier %></span>
                            <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                          </div>
                        </td>
                        <td><%= entry.attempt %></td>
                        <td class="mono"><%= entry.due_at || "n/a" %></td>
                        <td><%= entry.error || "n/a" %></td>
                      </tr>
                    </tbody>
                  </table>
                </div>

                <div class="mobile-list">
                  <article :for={entry <- @payload.retrying} class="mobile-card mobile-card-muted">
                    <div class="mobile-card-header">
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>

                      <span class="state-badge state-badge-warning">Retry</span>
                    </div>

                    <div class="mobile-detail-grid">
                      <div class="mobile-detail-row">
                        <span class="mobile-detail-label">Attempt</span>
                        <span class="mobile-detail-value numeric"><%= entry.attempt %></span>
                      </div>

                      <div class="mobile-detail-row">
                        <span class="mobile-detail-label">Due at</span>
                        <span class="mobile-detail-value mono"><%= entry.due_at || "n/a" %></span>
                      </div>

                      <div class="mobile-detail-row">
                        <span class="mobile-detail-label">Error</span>
                        <span class="mobile-detail-value"><%= entry.error || "n/a" %></span>
                      </div>
                    </div>
                  </article>
                </div>
              <% end %>
            </section>
          </div>

          <div class="live-side">
            <section class="section-card section-card-secondary">
              <div class="section-header">
                <div>
                  <h2 class="section-title">Rate limits</h2>
                  <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
                </div>
              </div>

              <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
            </section>

            <section class="section-card section-card-secondary">
              <div class="section-header">
                <div>
                  <h2 class="section-title">Runtime identity</h2>
                  <p class="section-copy">Version, workflow, and host details for this Symphony runtime.</p>
                </div>
              </div>

              <div class="identity-grid">
                <article class="identity-item">
                  <p class="identity-label">Version</p>
                  <p class="identity-value mono"><%= runtime_value(@payload, [:app, :version]) || "n/a" %></p>
                </article>

                <article class="identity-item">
                  <p class="identity-label">Model / effort</p>
                  <p class="identity-value mono">
                    <%= runtime_value(@payload, [:config, :codex, :model]) || "n/a" %>
                    ·
                    <%= runtime_value(@payload, [:config, :codex, :reasoning_effort]) || "n/a" %>
                  </p>
                </article>

                <article class="identity-item">
                  <p class="identity-label">Host / pid</p>
                  <p class="identity-value mono">
                    <%= runtime_value(@payload, [:system, :hostname]) || "n/a" %>
                    ·
                    <%= runtime_value(@payload, [:system, :os_pid]) || "n/a" %>
                  </p>
                </article>

                <article class="identity-item">
                  <p class="identity-label">Started</p>
                  <p class="identity-value mono"><%= runtime_value(@payload, [:runtime, :started_at]) || "n/a" %></p>
                </article>

                <article class="identity-item identity-item-wide">
                  <p class="identity-label">Workflow</p>
                  <p class="identity-value mono"><%= runtime_value(@payload, [:workflow, :path]) || "n/a" %></p>
                  <p class="identity-meta mono muted">
                    sha <%= short_hash(runtime_value(@payload, [:workflow, :sha256])) %>
                    <%= if runtime_value(@payload, [:workflow, :mtime]) do %>
                      · mtime <%= runtime_value(@payload, [:workflow, :mtime]) %>
                    <% end %>
                  </p>
                </article>

                <article class="identity-item identity-item-wide">
                  <p class="identity-label">Agent CLI</p>
                  <p class="identity-value mono">
                    <%= runtime_value(@payload, [:config, :codex, :binary_name]) || "n/a" %>
                    <%= if runtime_value(@payload, [:config, :codex, :binary_path]) do %>
                      · <%= runtime_value(@payload, [:config, :codex, :binary_path]) %>
                    <% end %>
                  </p>
                  <p class="identity-meta mono muted">
                    <%= runtime_value(@payload, [:config, :codex, :binary_version]) || "version unavailable" %>
                  </p>
                </article>

                <article class="identity-item">
                  <p class="identity-label">Server</p>
                  <p class="identity-value mono">
                    <%= runtime_value(@payload, [:config, :server, :host]) || "n/a" %>:<%= runtime_value(@payload, [:config, :server, :port]) || "n/a" %>
                  </p>
                </article>

                <article class="identity-item">
                  <p class="identity-label">Concurrency</p>
                  <p class="identity-value mono"><%= runtime_value(@payload, [:config, :agent, :max_concurrent_agents]) || "n/a" %></p>
                </article>

                <article class="identity-item identity-item-wide">
                  <p class="identity-label">History file</p>
                  <p class="identity-value mono"><%= runtime_value(@payload, [:runtime, :history_path]) || "n/a" %></p>
                </article>

                <article class="identity-item identity-item-wide">
                  <p class="identity-label">Active states</p>
                  <p class="identity-value"><%= join_list(runtime_value(@payload, [:config, :tracker, :active_states])) %></p>
                </article>
              </div>
            </section>
          </div>
        </div>

        <section class="section-card section-card-secondary">
          <div class="section-header">
            <div>
              <h2 class="section-title">Runtime history</h2>
              <p class="section-copy">Persisted operator history that survives Symphony restarts.</p>
            </div>
          </div>

          <div class="metric-grid metric-grid-history">
            <article class="metric-card metric-card-subtle">
              <p class="metric-label">Lifetime tokens</p>
              <p class="metric-value numeric"><%= format_int(history_value(@payload, [:lifetime_codex_totals, :total_tokens])) %></p>
              <p class="metric-detail numeric">
                In <%= format_int(history_value(@payload, [:lifetime_codex_totals, :input_tokens])) %> / Out <%= format_int(history_value(@payload, [:lifetime_codex_totals, :output_tokens])) %>
              </p>
            </article>

            <article class="metric-card metric-card-subtle">
              <p class="metric-label">Lifetime runtime</p>
              <p class="metric-value numeric"><%= format_runtime_seconds(history_value(@payload, [:lifetime_codex_totals, :seconds_running]) || 0) %></p>
              <p class="metric-detail">Persisted completed-session runtime.</p>
            </article>

            <article class="metric-card metric-card-subtle">
              <p class="metric-label">Recent sessions</p>
              <p class="metric-value numeric"><%= length(history_session_groups(@payload)) %></p>
              <p class="metric-detail">Grouped completed or interrupted runs.</p>
            </article>

            <article class="metric-card metric-card-subtle">
              <p class="metric-label">Recent retries</p>
              <p class="metric-value numeric"><%= length(history_retry_groups(@payload)) %></p>
              <p class="metric-detail">Grouped scheduled retry events across restarts.</p>
            </article>
          </div>

          <div class="history-grid">
            <section class="history-column">
              <h3 class="history-title">Recent sessions</h3>
              <%= if history_session_groups(@payload) == [] do %>
                <p class="empty-state">No persisted session history yet.</p>
              <% else %>
                <article :for={entry <- history_session_groups(@payload)} class="history-entry">
                  <div class="history-entry-header">
                    <div class="history-title-stack">
                      <span class="issue-id"><%= entry.issue_identifier || "n/a" %></span>
                      <p class="history-summary"><%= entry.summary %></p>
                    </div>
                    <div class="history-badge-stack">
                      <span class={state_badge_class(entry.issue_state || entry.summary || "n/a")}>
                        <%= entry.issue_state || "n/a" %>
                      </span>
                      <span :if={entry.count > 1} class="history-count mono">x<%= entry.count %></span>
                    </div>
                  </div>
                  <p class="history-entry-copy mono">
                    <%= entry.finished_at || "n/a" %> · <%= format_runtime_seconds(entry.runtime_seconds || 0) %> ·
                    tokens <%= format_int(entry.total_tokens) %>
                  </p>
                  <p class="history-entry-copy muted mono">
                    session <%= entry.session_id || "n/a" %>
                    <%= if entry.count > 1 and entry.oldest_finished_at do %>
                      · first seen <%= entry.oldest_finished_at %>
                    <% end %>
                  </p>
                </article>
              <% end %>
            </section>

            <section class="history-column">
              <h3 class="history-title">Recent retries</h3>
              <%= if history_retry_groups(@payload) == [] do %>
                <p class="empty-state">No persisted retry history yet.</p>
              <% else %>
                <article :for={entry <- history_retry_groups(@payload)} class="history-entry history-entry-muted">
                  <div class="history-entry-header">
                    <div class="history-title-stack">
                      <span class="issue-id"><%= entry.issue_identifier || "n/a" %></span>
                      <p class="history-summary"><%= entry.summary %></p>
                    </div>
                    <div class="history-badge-stack">
                      <span class="state-badge state-badge-warning">Attempt <%= entry.attempt || 0 %></span>
                      <span :if={entry.count > 1} class="history-count mono">x<%= entry.count %></span>
                    </div>
                  </div>
                  <p class="history-entry-copy mono">
                    <%= entry.scheduled_at || "n/a" %> · due <%= entry.due_at || "n/a" %>
                  </p>
                  <p class="history-entry-copy muted mono">
                    <%= if entry.count > 1 and entry.oldest_scheduled_at do %>
                      first seen <%= entry.oldest_scheduled_at %>
                    <% else %>
                      latest grouped retry
                    <% end %>
                  </p>
                </article>
              <% end %>
            </section>
          </div>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp process_uptime_seconds(payload, now) do
    payload
    |> runtime_value([:runtime, :started_at])
    |> runtime_seconds_from_started_at(now)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_age(seconds) when is_number(seconds), do: format_runtime_seconds(seconds)
  defp format_age(_seconds), do: "n/a"

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp flash_message(flash, kind) do
    Phoenix.Flash.get(flash, kind)
  end

  defp runtime_value(payload, path), do: deep_get(Map.get(payload, :runtime, %{}), path)
  defp history_value(payload, path), do: deep_get(Map.get(payload, :history, %{}), path)
  defp history_sessions(payload), do: Map.get(Map.get(payload, :history, %{}), :recent_sessions, [])
  defp history_retries(payload), do: Map.get(Map.get(payload, :history, %{}), :recent_retries, [])
  defp history_session_groups(payload), do: history_sessions(payload) |> group_history_sessions()
  defp history_retry_groups(payload), do: history_retries(payload) |> group_history_retries()

  defp operator_banner_title(%{error: _error}, _now), do: "Dashboard cannot read the runtime"

  defp operator_banner_title(payload, now) do
    cond do
      stalled_running_entries(payload, now) != [] -> "Operator action needed"
      snapshot_stale?(payload, now) -> "Snapshot needs a refresh"
      payload.counts.retrying > 0 and payload.counts.running == 0 -> "Runtime is healthy, but work is backing off"
      payload.counts.running > 0 -> "Runtime is actively working"
      true -> "Runtime is healthy and idle"
    end
  end

  defp operator_banner_body(%{error: error}, _now) do
    "Snapshot requests are failing with #{error.code}. Check the orchestrator process and retry a runtime refresh."
  end

  defp operator_banner_body(payload, now) do
    stalled = length(stalled_running_entries(payload, now))

    cond do
      stalled > 0 ->
        "#{stalled} running session(s) have gone at least #{format_age(@session_stalled_seconds)} without a fresh Codex event. Check the stalled issue row and recent logs first."

      snapshot_stale?(payload, now) ->
        "The dashboard payload is #{format_age(snapshot_age_seconds(payload, now))} old. LiveView is connected, but Symphony has not published a fresh snapshot recently."

      payload.counts.retrying > 0 and payload.counts.running == 0 ->
        "#{payload.counts.retrying} issue(s) are currently backing off. Review retry errors and queue pressure before forcing a restart."

      payload.counts.running > 0 ->
        "#{payload.counts.running} issue session(s) are active right now. Use the running table below to inspect activity, last events, and token burn."

      true ->
        "There are no active sessions, no queued retries, and no stalled workers. If you expected activity, confirm that eligible Linear issues exist under the active workflow."
    end
  end

  defp operator_banner_class(payload, now) do
    base = "section-card operator-banner"

    cond do
      payload[:error] -> "#{base} operator-banner-danger"
      stalled_running_entries(payload, now) != [] -> "#{base} operator-banner-danger"
      snapshot_stale?(payload, now) -> "#{base} operator-banner-warning"
      payload.counts.retrying > 0 -> "#{base} operator-banner-warning"
      true -> "#{base} operator-banner-good"
    end
  end

  defp running_empty_state(payload, now) do
    cond do
      payload.counts.retrying > 0 ->
        "No active sessions right now. Work is currently waiting in the retry queue."

      snapshot_stale?(payload, now) ->
        "No active sessions are visible in the current snapshot. Refresh the runtime if you expected active work."

      true ->
        "No active sessions. The runtime currently looks healthy and idle."
    end
  end

  defp retry_empty_state(payload, now) do
    cond do
      payload.counts.running > 0 ->
        "No issues are currently backing off. Active work is proceeding without queued retries."

      snapshot_stale?(payload, now) ->
        "No queued retries are visible in the current snapshot."

      true ->
        "No issues are currently backing off."
    end
  end

  defp runtime_health_label(%{error: _error}, _now), do: "Runtime unavailable"

  defp runtime_health_label(payload, now) do
    cond do
      stalled_running_entries(payload, now) != [] -> "Stalled sessions"
      snapshot_stale?(payload, now) -> "Snapshot stale"
      payload.counts.retrying > 0 -> "Retry pressure"
      true -> "Runtime healthy"
    end
  end

  defp runtime_health_badge_class(payload, now) do
    base = "status-badge"

    cond do
      payload[:error] -> "#{base} status-badge-danger"
      stalled_running_entries(payload, now) != [] -> "#{base} status-badge-danger"
      snapshot_stale?(payload, now) -> "#{base} status-badge-warning"
      payload.counts.retrying > 0 -> "#{base} status-badge-warning"
      true -> "#{base} status-badge-good"
    end
  end

  defp show_attention_panel?(%{error: _error}, _now), do: true

  defp show_attention_panel?(payload, now) do
    snapshot_stale?(payload, now) or payload.counts.retrying > 0 or stalled_running_entries(payload, now) != []
  end

  defp snapshot_stale?(payload, now), do: snapshot_age_seconds(payload, now) >= @snapshot_stale_seconds

  defp snapshot_age_seconds(%{generated_at: generated_at}, now) do
    runtime_seconds_from_started_at(generated_at, now)
  end

  defp snapshot_age_seconds(_payload, _now), do: 0

  defp stalled_running_entries(payload, now) do
    Enum.filter(payload.running, &session_stalled?(&1, now))
  end

  defp session_stalled?(entry, now), do: session_activity_age_seconds(entry, now) >= @session_stalled_seconds

  defp session_activity_age_seconds(entry, now) do
    event_age = runtime_seconds_from_started_at(entry.last_event_at, now)

    cond do
      event_age > 0 -> event_age
      true -> runtime_seconds_from_started_at(entry.started_at, now)
    end
  end

  defp session_health_label(entry, now) do
    activity_age = session_activity_age_seconds(entry, now)

    cond do
      entry.last_event_at == nil and activity_age < @session_waiting_seconds -> "Starting"
      activity_age < @session_waiting_seconds -> "Active"
      activity_age < @session_stalled_seconds -> "Waiting"
      true -> "Stalled"
    end
  end

  defp session_health_detail(entry, now) do
    cond do
      entry.last_event_at ->
        "Last event #{format_age(session_activity_age_seconds(entry, now))} ago"

      true ->
        "No Codex event yet"
    end
  end

  defp session_health_badge_class(entry, now) do
    base = "state-badge"

    case session_health_label(entry, now) do
      "Active" -> "#{base} state-badge-active"
      "Starting" -> "#{base} state-badge-active"
      "Waiting" -> "#{base} state-badge-warning"
      "Stalled" -> "#{base} state-badge-danger"
      _ -> base
    end
  end

  defp short_hash(hash) when is_binary(hash), do: String.slice(hash, 0, 12)
  defp short_hash(_hash), do: "n/a"

  defp join_list(values) when is_list(values), do: Enum.join(values, ", ")
  defp join_list(_values), do: "n/a"

  defp deep_get(data, []), do: data

  defp deep_get(data, [key | rest]) when is_map(data) do
    value =
      Map.get(data, key) ||
        Map.get(data, to_string(key))

    deep_get(value, rest)
  end

  defp deep_get(_data, _path), do: nil

  defp group_history_sessions(entries) when is_list(entries) do
    entries
    |> Enum.map(&normalize_history_session/1)
    |> Enum.reduce([], fn entry, acc ->
      case acc do
        [head | rest] ->
          if history_session_group_key(head) == history_session_group_key(entry) do
            [
              %{
                head
                | count: head.count + 1,
                  oldest_finished_at: entry.finished_at || head.oldest_finished_at,
                  oldest_started_at: entry.started_at || head.oldest_started_at
              }
              | rest
            ]
          else
            [Map.put(entry, :count, 1) | acc]
          end

        _ ->
          [Map.put(entry, :count, 1) | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp group_history_sessions(_entries), do: []

  defp normalize_history_session(entry) when is_map(entry) do
    %{
      issue_identifier: entry[:issue_identifier],
      issue_state: entry[:issue_state],
      summary: summarize_history_result(entry),
      session_id: entry[:session_id],
      finished_at: entry[:finished_at],
      oldest_finished_at: entry[:finished_at],
      started_at: entry[:started_at],
      oldest_started_at: entry[:started_at],
      runtime_seconds: entry[:runtime_seconds] || 0,
      total_tokens: deep_get(entry, [:totals, :total_tokens]) || 0
    }
  end

  defp history_session_group_key(entry) do
    {entry.issue_identifier, entry.issue_state, entry.summary}
  end

  defp group_history_retries(entries) when is_list(entries) do
    entries
    |> Enum.map(&normalize_history_retry/1)
    |> Enum.reduce([], fn entry, acc ->
      case acc do
        [head | rest] ->
          if history_retry_group_key(head) == history_retry_group_key(entry) do
            [
              %{
                head
                | count: head.count + 1,
                  attempt: max(head.attempt || 0, entry.attempt || 0),
                  oldest_scheduled_at: entry.scheduled_at || head.oldest_scheduled_at,
                  due_at: head.due_at || entry.due_at
              }
              | rest
            ]
          else
            [Map.put(entry, :count, 1) | acc]
          end

        _ ->
          [Map.put(entry, :count, 1) | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp group_history_retries(_entries), do: []

  defp normalize_history_retry(entry) when is_map(entry) do
    %{
      issue_identifier: entry[:issue_identifier],
      attempt: entry[:attempt] || 0,
      summary: summarize_history_error(entry[:error]),
      scheduled_at: entry[:scheduled_at],
      oldest_scheduled_at: entry[:scheduled_at],
      due_at: entry[:due_at]
    }
  end

  defp history_retry_group_key(entry) do
    {entry.issue_identifier, entry.summary}
  end

  defp summarize_history_result(nil), do: "n/a"

  defp summarize_history_result(entry) when is_map(entry) do
    case Map.get(entry, :stop_reason) do
      "terminal_state" ->
        case Map.get(entry, :to_state) do
          "Done" -> "landed and moved to Done"
          state when is_binary(state) -> "moved to terminal state #{state}"
          _ -> summarize_history_result(Map.get(entry, :result))
        end

      "state_changed" ->
        case Map.get(entry, :to_state) do
          state when is_binary(state) -> "stopped after state transition to #{state}"
          _ -> summarize_history_result(Map.get(entry, :result))
        end

      "completed" ->
        "completed normally"

      "agent_error" ->
        summarize_history_result(Map.get(entry, :result))

      _ ->
        summarize_history_result(Map.get(entry, :result))
    end
  end

  defp summarize_history_result(result) when is_binary(result) do
    cond do
      String.contains?(result, "workspace_hook_failed") and String.contains?(result, "not trusted") ->
        "before_run failed: workspace mise.toml was not trusted"

      String.starts_with?(result, "agent exited:") ->
        result
        |> String.replace_prefix("agent exited:", "")
        |> String.trim()
        |> truncate_history_text(120)
        |> then(&"agent exited: #{&1}")

      true ->
        truncate_history_text(result, 120)
    end
  end

  defp summarize_history_result(result), do: result |> to_string() |> summarize_history_result()

  defp summarize_history_error(nil), do: "n/a"

  defp summarize_history_error(error) when is_binary(error) do
    cond do
      String.contains?(error, "workspace_hook_failed") and String.contains?(error, "not trusted") ->
        "before_run failed: workspace mise.toml was not trusted"

      String.starts_with?(error, "agent exited:") ->
        error
        |> String.replace_prefix("agent exited:", "")
        |> String.trim()
        |> truncate_history_text(120)
        |> then(&"agent exited: #{&1}")

      true ->
        truncate_history_text(error, 120)
    end
  end

  defp summarize_history_error(error), do: error |> to_string() |> summarize_history_error()

  defp truncate_history_text(text, limit) when is_binary(text) do
    condensed =
      text
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(condensed) > limit do
      String.slice(condensed, 0, limit - 1) <> "…"
    else
      condensed
    end
  end

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp reconcile_history_message(%{updated_entries: updated_entries} = payload)
       when is_integer(updated_entries) and updated_entries > 0 do
    "Reconciled history: repaired #{updated_entries} session entries across #{payload.issues_found || 0} current issues."
  end

  defp reconcile_history_message(_payload) do
    "Reconciled history: no stale terminal-session entries needed repair."
  end

  defp refresh_runtime_message(%{coalesced: true}) do
    "Runtime refresh requested. Symphony was already polling or reconciling, so the request was coalesced."
  end

  defp refresh_runtime_message(_payload) do
    "Runtime refresh requested. Symphony will poll and reconcile immediately."
  end

  defp reconcile_history_error(payload) when is_map(payload) do
    "History reconciliation failed: #{Map.get(payload, :error, "unknown error")}."
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end

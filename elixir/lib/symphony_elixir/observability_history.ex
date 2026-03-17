defmodule SymphonyElixir.ObservabilityHistory do
  @moduledoc """
  Persists runtime-only observability history that should survive orchestrator restarts.
  """

  require Logger
  alias SymphonyElixir.Linear.Issue

  @session_limit 20
  @retry_limit 40
  @empty_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  @spec default_path() :: String.t()
  def default_path do
    Application.get_env(:symphony_elixir, :observability_history_path) ||
      Path.join([System.user_home!(), ".config", "symphony", "observability_history.json"])
  end

  @spec default_history() :: map()
  def default_history do
    %{
      lifetime_codex_totals: @empty_totals,
      recent_sessions: [],
      recent_retries: []
    }
  end

  @spec load(String.t()) :: map()
  def load(path \\ default_path()) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, payload} when is_map(payload) ->
            normalize_history(payload)

          {:ok, _payload} ->
            default_history()

          {:error, reason} ->
            Logger.warning("Failed to decode observability history path=#{path}: #{inspect(reason)}")
            default_history()
        end

      {:error, :enoent} ->
        default_history()

      {:error, reason} ->
        Logger.warning("Failed to read observability history path=#{path}: #{inspect(reason)}")
        default_history()
    end
  end

  @spec persist(map(), String.t()) :: :ok
  def persist(history, path \\ default_path()) when is_map(history) and is_binary(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, payload} <- Jason.encode(history, pretty: true),
         :ok <- File.write(path, payload <> "\n") do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to persist observability history path=#{path}: #{inspect(reason)}")
        :ok
    end
  end

  @spec append_session(map(), map()) :: map()
  def append_session(history, session_entry) when is_map(history) and is_map(session_entry) do
    history
    |> put_totals(:lifetime_codex_totals, session_entry[:totals] || %{})
    |> Map.put(:recent_sessions, prepend_limited(history[:recent_sessions], normalize_session_entry(session_entry), @session_limit))
  end

  @spec append_retry(map(), map()) :: map()
  def append_retry(history, retry_entry) when is_map(history) and is_map(retry_entry) do
    Map.put(
      history,
      :recent_retries,
      prepend_limited(history[:recent_retries], normalize_retry_entry(retry_entry), @retry_limit)
    )
  end

  @spec reconcilable_session_issue_ids(map()) :: [String.t()]
  def reconcilable_session_issue_ids(history) when is_map(history) do
    history
    |> Map.get(:recent_sessions, [])
    |> Enum.flat_map(fn entry ->
      entry = normalize_session_entry(entry)

      if reconcilable_terminal_session?(entry) and is_binary(entry.issue_id) and entry.issue_id != "" do
        [entry.issue_id]
      else
        []
      end
    end)
    |> Enum.uniq()
  end

  @spec reconcile_terminal_session_history(map(), [Issue.t() | map()]) :: {map(), map()}
  def reconcile_terminal_session_history(history, issues)
      when is_map(history) and is_list(issues) do
    state_by_issue_id = issue_state_by_id(issues)

    {recent_sessions, summary} =
      history
      |> Map.get(:recent_sessions, [])
      |> Enum.map(&normalize_session_entry/1)
      |> Enum.map_reduce(
        %{candidate_entries: 0, updated_entries: 0, missing_issues: MapSet.new()},
        fn entry, summary ->
          if reconcilable_terminal_session?(entry) do
            summary = %{summary | candidate_entries: summary.candidate_entries + 1}

            case Map.get(state_by_issue_id, entry.issue_id) do
              state when is_binary(state) and state != "" ->
                updated_entry = reconcile_terminal_session_entry(entry, state)

                summary =
                  if updated_entry == entry do
                    summary
                  else
                    %{summary | updated_entries: summary.updated_entries + 1}
                  end

                {updated_entry, summary}

              _ ->
                summary = %{summary | missing_issues: MapSet.put(summary.missing_issues, entry.issue_id)}
                {entry, summary}
            end
          else
            {entry, summary}
          end
        end
      )

    {
      Map.put(history, :recent_sessions, recent_sessions),
      %{
        candidate_entries: summary.candidate_entries,
        updated_entries: summary.updated_entries,
        issues_found: map_size(state_by_issue_id),
        missing_issues: MapSet.size(summary.missing_issues)
      }
    }
  end

  defp normalize_history(payload) do
    %{
      lifetime_codex_totals: normalize_totals(Map.get(payload, "lifetime_codex_totals")),
      recent_sessions:
        payload
        |> Map.get("recent_sessions", [])
        |> normalize_list(&normalize_session_entry/1, @session_limit),
      recent_retries:
        payload
        |> Map.get("recent_retries", [])
        |> normalize_list(&normalize_retry_entry/1, @retry_limit)
    }
  end

  defp normalize_list(list, mapper, limit) when is_list(list) do
    list
    |> Enum.map(mapper)
    |> Enum.take(limit)
  end

  defp normalize_list(_list, _mapper, _limit), do: []

  defp normalize_session_entry(entry) when is_map(entry) do
    %{
      issue_id: map_get(entry, "issue_id", :issue_id),
      issue_identifier: map_get(entry, "issue_identifier", :issue_identifier),
      issue_state: map_get(entry, "issue_state", :issue_state),
      session_id: map_get(entry, "session_id", :session_id),
      turn_count: map_get(entry, "turn_count", :turn_count) || 0,
      started_at: map_get(entry, "started_at", :started_at),
      finished_at: map_get(entry, "finished_at", :finished_at),
      runtime_seconds: map_get(entry, "runtime_seconds", :runtime_seconds) || 0,
      last_event: map_get(entry, "last_event", :last_event),
      result: map_get(entry, "result", :result),
      stop_reason: map_get(entry, "stop_reason", :stop_reason),
      from_state: map_get(entry, "from_state", :from_state),
      to_state: map_get(entry, "to_state", :to_state),
      workspace_path: map_get(entry, "workspace_path", :workspace_path),
      worker_host: map_get(entry, "worker_host", :worker_host),
      totals: normalize_totals(map_get(entry, "totals", :totals))
    }
  end

  defp normalize_retry_entry(entry) when is_map(entry) do
    %{
      issue_id: map_get(entry, "issue_id", :issue_id),
      issue_identifier: map_get(entry, "issue_identifier", :issue_identifier),
      attempt: map_get(entry, "attempt", :attempt) || 0,
      error: map_get(entry, "error", :error),
      scheduled_at: map_get(entry, "scheduled_at", :scheduled_at),
      delay_ms: map_get(entry, "delay_ms", :delay_ms) || 0,
      due_at: map_get(entry, "due_at", :due_at),
      workspace_path: map_get(entry, "workspace_path", :workspace_path),
      worker_host: map_get(entry, "worker_host", :worker_host)
    }
  end

  defp normalize_totals(totals) when is_map(totals) do
    %{
      input_tokens: map_get(totals, "input_tokens", :input_tokens) || 0,
      output_tokens: map_get(totals, "output_tokens", :output_tokens) || 0,
      total_tokens: map_get(totals, "total_tokens", :total_tokens) || 0,
      seconds_running: map_get(totals, "seconds_running", :seconds_running) || 0
    }
  end

  defp normalize_totals(_totals), do: @empty_totals

  defp issue_state_by_id(issues) do
    Enum.reduce(issues, %{}, fn
      %Issue{id: issue_id, state: state}, acc when is_binary(issue_id) and is_binary(state) ->
        Map.put(acc, issue_id, state)

      %{"id" => issue_id, "state" => state}, acc when is_binary(issue_id) and is_binary(state) ->
        Map.put(acc, issue_id, state)

      %{id: issue_id, state: state}, acc when is_binary(issue_id) and is_binary(state) ->
        Map.put(acc, issue_id, state)

      _issue, acc ->
        acc
    end)
  end

  defp reconcilable_terminal_session?(entry) do
    stop_reason = entry[:stop_reason]
    result = entry[:result]

    (stop_reason == "terminal_state" or result == "moved to terminal state") and
      is_binary(entry[:issue_id]) and entry[:issue_id] != ""
  end

  defp reconcile_terminal_session_entry(entry, state) when is_binary(state) do
    from_state =
      cond do
        is_binary(entry[:from_state]) and entry[:from_state] != "" ->
          entry[:from_state]

        is_binary(entry[:issue_state]) and entry[:issue_state] != state ->
          entry[:issue_state]

        true ->
          nil
      end

    %{
      entry
      | issue_state: state,
        stop_reason: entry[:stop_reason] || "terminal_state",
        from_state: from_state,
        to_state: state
    }
  end

  defp put_totals(history, key, totals) do
    Map.put(history, key, add_totals(history[key] || @empty_totals, normalize_totals(totals)))
  end

  defp add_totals(existing, delta) do
    %{
      input_tokens: (existing[:input_tokens] || 0) + (delta[:input_tokens] || 0),
      output_tokens: (existing[:output_tokens] || 0) + (delta[:output_tokens] || 0),
      total_tokens: (existing[:total_tokens] || 0) + (delta[:total_tokens] || 0),
      seconds_running: (existing[:seconds_running] || 0) + (delta[:seconds_running] || 0)
    }
  end

  defp prepend_limited(list, entry, limit) when is_list(list) do
    [entry | list]
    |> Enum.take(limit)
  end

  defp prepend_limited(_list, entry, _limit), do: [entry]

  defp map_get(map, string_key, atom_key) do
    Map.get(map, atom_key) || Map.get(map, string_key)
  end
end

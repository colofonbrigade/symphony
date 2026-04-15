defmodule CLI.StatusDashboard do
  @moduledoc """
  Pure rendering for the terminal status dashboard.

  `format_snapshot_content/4` takes the orchestrator snapshot plus a context
  map (project slug, dashboard URL inputs, agent caps, terminal width) and
  returns the fully-formatted ANSI string that `Core.StatusDashboard` writes
  to stdout. Everything here is side-effect free — no Application env reads,
  no process calls, no I/O. Core composes Config reads and hands the values
  in.
  """

  alias CLI.StatusDashboard.AgentMessage

  @default_terminal_columns 115
  @running_age_width 12
  @running_event_default_width 44
  @running_event_min_width 12
  @running_id_width 8
  @running_pid_width 8
  @running_row_chrome_width 10
  @running_session_width 14
  @running_stage_width 14
  @running_tokens_width 10
  @sparkline_blocks ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
  @throughput_graph_columns 24
  @throughput_graph_window_ms 10 * 60 * 1000
  @throughput_window_ms 5_000

  @ansi_reset IO.ANSI.reset()
  @ansi_bold IO.ANSI.bright()
  @ansi_blue IO.ANSI.blue()
  @ansi_cyan IO.ANSI.cyan()
  @ansi_dim IO.ANSI.faint()
  @ansi_green IO.ANSI.green()
  @ansi_red IO.ANSI.red()
  @ansi_orange IO.ANSI.yellow()
  @ansi_yellow IO.ANSI.yellow()
  @ansi_magenta IO.ANSI.magenta()
  @ansi_gray IO.ANSI.light_black()

  @type context :: %{
          required(:max_agents) => non_neg_integer(),
          required(:dashboard_host) => String.t(),
          required(:dashboard_port) => non_neg_integer() | nil,
          required(:project_slug) => String.t() | nil
        }

  @spec format_snapshot_content(term(), number(), context(), integer() | nil) :: String.t()
  def format_snapshot_content(snapshot_data, tps, context, terminal_columns_override \\ nil)

  # credo:disable-for-next-line
  def format_snapshot_content({:ok, snapshot} = snapshot_data, tps, context, terminal_columns_override) do
    _ = snapshot_data
    %{running: running, retrying: retrying, agent_totals: agent_totals} = snapshot
    project_link_lines = format_project_link_lines(context)
    project_refresh_line = format_project_refresh_line(Map.get(snapshot, :polling))
    agent_input_tokens = Map.get(agent_totals, :input_tokens, 0)
    agent_output_tokens = Map.get(agent_totals, :output_tokens, 0)
    agent_total_tokens = Map.get(agent_totals, :total_tokens, 0)
    agent_seconds_running = Map.get(agent_totals, :seconds_running, 0)
    agent_cost_usd = Map.get(agent_totals, :cost_usd, 0.0)
    agent_count = length(running)
    max_agents = context.max_agents
    running_event_width = running_event_width(terminal_columns_override)
    running_rows = format_running_rows(running, running_event_width)
    running_to_backoff_spacer = if(running == [], do: [], else: ["│"])
    backoff_rows = format_retry_rows(retrying)

    ([
       colorize("╭─ SYMPHONY STATUS", @ansi_bold),
       colorize("│ Agents: ", @ansi_bold) <>
         colorize("#{agent_count}", @ansi_green) <>
         colorize("/", @ansi_gray) <>
         colorize("#{max_agents}", @ansi_gray),
       colorize("│ Throughput: ", @ansi_bold) <>
         colorize("#{format_tps(tps)} tps", @ansi_cyan),
       colorize("│ Runtime: ", @ansi_bold) <>
         colorize(format_runtime_seconds(agent_seconds_running), @ansi_magenta),
       colorize("│ Tokens: ", @ansi_bold) <>
         colorize("in #{format_count(agent_input_tokens)}", @ansi_yellow) <>
         colorize(" | ", @ansi_gray) <>
         colorize("out #{format_count(agent_output_tokens)}", @ansi_yellow) <>
         colorize(" | ", @ansi_gray) <>
         colorize("total #{format_count(agent_total_tokens)}", @ansi_yellow),
       colorize("│ Cost: ", @ansi_bold) <>
         colorize("$#{format_cost_usd(agent_cost_usd)}", @ansi_cyan),
       rate_limit_header_line(running),
       project_link_lines,
       project_refresh_line,
       colorize("├─ Running", @ansi_bold),
       "│",
       running_table_header_row(running_event_width),
       running_table_separator_row(running_event_width)
     ] ++
       running_rows ++
       running_to_backoff_spacer ++
       [colorize("├─ Backoff queue", @ansi_bold), "│"] ++
       backoff_rows ++
       [closing_border()])
    |> List.flatten()
    |> Enum.join("\n")
  end

  def format_snapshot_content(:error, tps, context, _terminal_columns_override) do
    [
      colorize("╭─ SYMPHONY STATUS", @ansi_bold),
      colorize("│ Orchestrator snapshot unavailable", @ansi_red),
      colorize("│ Throughput: ", @ansi_bold) <> colorize("#{format_tps(tps)} tps", @ansi_cyan),
      format_project_link_lines(context),
      format_project_refresh_line(nil),
      closing_border()
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @spec render_offline_status_content() :: String.t()
  def render_offline_status_content do
    [
      colorize("╭─ SYMPHONY STATUS", @ansi_bold),
      colorize("│ app_status=offline", @ansi_red),
      closing_border()
    ]
    |> Enum.join("\n")
  end

  @spec render_to_terminal(String.t()) :: :ok
  def render_to_terminal(content) do
    IO.write([
      IO.ANSI.home(),
      IO.ANSI.clear(),
      normalize_status_lines(content),
      "\n"
    ])

    :ok
  end

  @doc """
  Render an agent event message into a short human-readable string for the
  dashboard. Delegates to `CLI.StatusDashboard.AgentMessage`.
  """
  @spec humanize_agent_message(term()) :: String.t()
  defdelegate humanize_agent_message(message), to: AgentMessage

  @doc false
  @spec rolling_tps([{integer(), integer()}], integer(), integer()) :: float()
  def rolling_tps(samples, now_ms, current_tokens) do
    samples = [{now_ms, current_tokens} | samples]
    samples = prune_samples(samples, now_ms)

    case samples do
      [] ->
        0.0

      [_one] ->
        0.0

      _ ->
        first = List.last(samples)
        {start_ms, start_tokens} = first
        elapsed_ms = now_ms - start_ms
        delta_tokens = max(0, current_tokens - start_tokens)

        if elapsed_ms <= 0 do
          0.0
        else
          delta_tokens / (elapsed_ms / 1000.0)
        end
    end
  end

  @doc false
  @spec throttled_tps(
          integer() | nil,
          float() | nil,
          integer(),
          [{integer(), integer()}],
          integer()
        ) ::
          {integer(), float()}
  def throttled_tps(last_second, last_value, now_ms, token_samples, current_tokens) do
    second = div(now_ms, 1000)

    if is_integer(last_second) and last_second == second and is_number(last_value) do
      {second, last_value}
    else
      {second, rolling_tps(token_samples, now_ms, current_tokens)}
    end
  end

  @doc false
  @spec update_token_samples([{integer(), integer()}], integer(), integer()) :: [{integer(), integer()}]
  def update_token_samples(samples, now_ms, total_tokens) do
    prune_graph_samples([{now_ms, total_tokens} | samples], now_ms)
  end

  @doc false
  @spec prune_samples([{integer(), integer()}], integer()) :: [{integer(), integer()}]
  def prune_samples(samples, now_ms) do
    min_timestamp = now_ms - @throughput_window_ms
    Enum.filter(samples, fn {timestamp, _} -> timestamp >= min_timestamp end)
  end

  defp prune_graph_samples(samples, now_ms) do
    min_timestamp = now_ms - max(@throughput_window_ms, @throughput_graph_window_ms)
    Enum.filter(samples, fn {timestamp, _} -> timestamp >= min_timestamp end)
  end

  @doc """
  Format a running-agent entry as a single dashboard row. Used from
  `format_snapshot_content/4` and directly from tests that exercise a
  single-row layout.
  """
  @spec format_running_summary(map(), integer() | nil) :: String.t()
  def format_running_summary(running_entry, terminal_columns \\ nil) do
    format_running_row(running_entry, running_event_width(terminal_columns))
  end

  @doc """
  Build the full dashboard URL for a host/port pair, applying loopback and
  IPv6-bracketing normalization. Returns nil when `port` is nil or 0.
  """
  @spec dashboard_url(String.t(), non_neg_integer() | nil) :: String.t() | nil
  def dashboard_url(_host, nil), do: nil

  def dashboard_url(host, port) when is_integer(port) and port > 0 do
    "http://#{dashboard_url_host(host)}:#{port}/"
  end

  def dashboard_url(_host, _port), do: nil

  @doc """
  Render a sparkline string of tokens-per-second over the throughput graph
  window (10 minutes at 24 columns).
  """
  @spec tps_graph([{integer(), integer()}], integer(), integer()) :: String.t()
  def tps_graph(samples, now_ms, current_tokens) do
    bucket_ms = div(@throughput_graph_window_ms, @throughput_graph_columns)
    active_bucket_start = div(now_ms, bucket_ms) * bucket_ms
    graph_window_start = active_bucket_start - (@throughput_graph_columns - 1) * bucket_ms

    rates =
      [{now_ms, current_tokens} | samples]
      |> prune_graph_samples(now_ms)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{start_ms, start_tokens}, {end_ms, end_tokens}] ->
        elapsed_ms = end_ms - start_ms
        delta_tokens = max(0, end_tokens - start_tokens)
        tps = if elapsed_ms <= 0, do: 0.0, else: delta_tokens / (elapsed_ms / 1000.0)
        {end_ms, tps}
      end)

    bucketed_tps =
      0..(@throughput_graph_columns - 1)
      |> Enum.map(fn bucket_idx ->
        bucket_start = graph_window_start + bucket_idx * bucket_ms
        bucket_end = bucket_start + bucket_ms
        last_bucket? = bucket_idx == @throughput_graph_columns - 1

        values =
          rates
          |> Enum.filter(fn {timestamp, _tps} ->
            in_bucket?(timestamp, bucket_start, bucket_end, last_bucket?)
          end)
          |> Enum.map(fn {_timestamp, tps} -> tps end)

        if values == [] do
          0.0
        else
          Enum.sum(values) / length(values)
        end
      end)

    max_tps = Enum.max(bucketed_tps, fn -> 0.0 end)

    bucketed_tps
    |> Enum.map_join(fn value ->
      index =
        if max_tps <= 0 do
          0
        else
          round(value / max_tps * (length(@sparkline_blocks) - 1))
        end

      Enum.at(@sparkline_blocks, index, "▁")
    end)
  end

  @doc """
  Format an integer or numeric TPS value with thousands separators.
  """
  @spec format_tps(number()) :: String.t()
  def format_tps(value) when is_number(value) do
    value
    |> trunc()
    |> Integer.to_string()
    |> group_thousands()
  end

  @doc """
  Format a DateTime as a second-precision UTC string (the dashboard header
  timestamp).
  """
  @spec format_timestamp(DateTime.t()) :: String.t()
  def format_timestamp(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_string()
  end

  ## --- internal helpers --------------------------------------------------

  defp format_project_link_lines(context) do
    project_part =
      case context.project_slug do
        project_slug when is_binary(project_slug) and project_slug != "" ->
          colorize(linear_project_url(project_slug), @ansi_cyan)

        _ ->
          colorize("n/a", @ansi_gray)
      end

    project_line = colorize("│ Project: ", @ansi_bold) <> project_part

    case dashboard_url(context.dashboard_host, context.dashboard_port) do
      url when is_binary(url) ->
        [project_line, colorize("│ Dashboard: ", @ansi_bold) <> colorize(url, @ansi_cyan)]

      _ ->
        [project_line]
    end
  end

  defp format_project_refresh_line(%{checking?: true}) do
    colorize("│ Next refresh: ", @ansi_bold) <> colorize("checking now…", @ansi_cyan)
  end

  defp format_project_refresh_line(%{next_poll_in_ms: due_in_ms}) when is_integer(due_in_ms) do
    due_in_ms = max(due_in_ms, 0)
    seconds = div(due_in_ms + 999, 1000)
    colorize("│ Next refresh: ", @ansi_bold) <> colorize("#{seconds}s", @ansi_cyan)
  end

  defp format_project_refresh_line(_) do
    colorize("│ Next refresh: ", @ansi_bold) <> colorize("n/a", @ansi_gray)
  end

  defp linear_project_url(project_slug), do: "https://linear.app/project/#{project_slug}/issues"

  defp dashboard_url_host(host) when host in ["0.0.0.0", "::", "[::]", ""], do: "127.0.0.1"

  defp dashboard_url_host(host) when is_binary(host) do
    trimmed_host = String.trim(host)

    cond do
      trimmed_host in ["0.0.0.0", "::", "[::]", ""] ->
        "127.0.0.1"

      String.starts_with?(trimmed_host, "[") and String.ends_with?(trimmed_host, "]") ->
        trimmed_host

      String.contains?(trimmed_host, ":") ->
        "[#{trimmed_host}]"

      true ->
        trimmed_host
    end
  end

  defp format_running_rows(running, running_event_width) do
    if running == [] do
      [
        "│  " <> colorize("No active agents", @ansi_gray),
        "│"
      ]
    else
      running
      |> Enum.sort_by(& &1.identifier)
      |> Enum.map(&format_running_row(&1, running_event_width))
    end
  end

  # credo:disable-for-next-line
  defp format_running_row(running_entry, running_event_width) do
    issue = format_cell(running_entry.identifier || "unknown", @running_id_width)
    state = running_entry.state || "unknown"
    state_display = format_cell(to_string(state), @running_stage_width)

    session =
      running_entry.session_id |> compact_session_id() |> format_cell(@running_session_width)

    pid = format_cell(running_entry.agent_pid || "n/a", @running_pid_width)
    total_tokens = running_entry.agent_total_tokens || 0
    runtime_seconds = running_entry.runtime_seconds || 0
    turn_count = Map.get(running_entry, :turn_count, 0)
    age = format_cell(format_runtime_and_turns(runtime_seconds, turn_count), @running_age_width)
    event = running_entry.last_agent_event || "none"

    event_label =
      format_cell(summarize_message(running_entry.last_agent_message), running_event_width)

    tokens = format_count(total_tokens) |> format_cell(@running_tokens_width, :right)

    status_color =
      case event do
        :none -> @ansi_red
        :startup_failed -> @ansi_red
        :turn_failed -> @ansi_red
        :turn_ended_with_error -> @ansi_red
        :turn_completed -> @ansi_magenta
        :session_started -> @ansi_green
        _ -> @ansi_blue
      end

    [
      "│ ",
      status_dot(status_color),
      " ",
      colorize(issue, @ansi_cyan),
      " ",
      colorize(state_display, status_color),
      " ",
      colorize(pid, @ansi_yellow),
      " ",
      colorize(age, @ansi_magenta),
      " ",
      colorize(tokens, @ansi_yellow),
      " ",
      colorize(session, @ansi_cyan),
      " ",
      colorize(event_label, status_color),
      rate_limit_badge(running_entry)
    ]
    |> Enum.join("")
  end

  defp rate_limit_badge(running_entry) do
    case Map.get(running_entry, :rate_limit_info) do
      %{} = info ->
        status = Map.get(info, "status") || Map.get(info, :status)

        if status in [nil, "allowed", :allowed] do
          ""
        else
          " " <> colorize("[#{status}]", @ansi_red)
        end

      _ ->
        ""
    end
  end

  defp rate_limit_header_line(running) when is_list(running) do
    throttled =
      running
      |> Enum.map(&Map.get(&1, :rate_limit_info))
      |> Enum.filter(&(is_map(&1) and rate_limit_status(&1) not in [nil, "allowed"]))

    case throttled do
      [] ->
        []

      infos ->
        statuses =
          infos
          |> Enum.map(&rate_limit_status/1)
          |> Enum.uniq()
          |> Enum.join(", ")

        earliest_reset =
          infos
          |> Enum.map(&rate_limit_resets_at/1)
          |> Enum.filter(&is_integer/1)
          |> Enum.min(fn -> nil end)

        reset_suffix =
          case earliest_reset do
            nil -> ""
            ts -> " · resets #{format_reset_time(ts)}"
          end

        colorize("│ Rate limit: ", @ansi_bold) <>
          colorize("#{statuses} · #{length(infos)} session(s)#{reset_suffix}", @ansi_red)
    end
  end

  defp rate_limit_status(info) when is_map(info),
    do: Map.get(info, "status") || Map.get(info, :status)

  defp rate_limit_resets_at(info) when is_map(info) do
    case Map.get(info, "resetsAt") || Map.get(info, :resetsAt) do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  defp format_reset_time(unix_seconds) when is_integer(unix_seconds) do
    case DateTime.from_unix(unix_seconds) do
      {:ok, dt} ->
        dt
        |> DateTime.shift_zone!("Etc/UTC")
        |> Calendar.strftime("%H:%M UTC")

      _ ->
        "?"
    end
  end

  defp format_retry_rows(retrying) do
    if retrying == [] do
      ["│  " <> colorize("No queued retries", @ansi_gray)]
    else
      retrying
      |> Enum.sort_by(& &1.due_in_ms)
      |> Enum.map_join(", ", &format_retry_summary/1)
      |> String.split(", ")
    end
  end

  defp format_retry_summary(retry_entry) do
    issue_id = retry_entry.issue_id || "unknown"
    identifier = retry_entry.identifier || issue_id
    attempt = retry_entry.attempt || 0
    due_in_ms = retry_entry.due_in_ms || 0
    error = format_retry_error(retry_entry.error)

    "│  #{colorize("↻", @ansi_orange)} " <>
      colorize("#{identifier}", @ansi_red) <>
      " " <>
      colorize("attempt=#{attempt}", @ansi_yellow) <>
      colorize(" in ", @ansi_dim) <>
      colorize(next_in_words(due_in_ms), @ansi_cyan) <>
      error
  end

  defp next_in_words(due_in_ms) when is_integer(due_in_ms) do
    secs = div(due_in_ms, 1000)
    millis = rem(due_in_ms, 1000)
    "#{secs}.#{String.pad_leading(to_string(millis), 3, "0")}s"
  end

  defp next_in_words(_), do: "n/a"

  defp format_retry_error(error) when is_binary(error) do
    sanitized =
      error
      |> String.replace("\\r\\n", " ")
      |> String.replace("\\r", " ")
      |> String.replace("\\n", " ")
      |> String.replace("\r\n", " ")
      |> String.replace("\r", " ")
      |> String.replace("\n", " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if sanitized == "" do
      ""
    else
      " " <> colorize("error=#{truncate(sanitized, 96)}", @ansi_dim)
    end
  end

  defp format_retry_error(_), do: ""

  defp format_cost_usd(value) when is_number(value) and value >= 0.0 do
    :erlang.float_to_binary(value * 1.0, decimals: 4)
  end

  defp format_cost_usd(_value), do: "0.0000"

  defp format_runtime_seconds(seconds) when is_integer(seconds) do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_runtime_seconds(seconds) when is_binary(seconds), do: seconds
  defp format_runtime_seconds(_), do: "0m 0s"

  defp format_runtime_and_turns(seconds, turn_count)
       when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(seconds)} / #{turn_count}"
  end

  defp format_runtime_and_turns(seconds, _turn_count), do: format_runtime_seconds(seconds)

  defp format_count(nil), do: "0"

  defp format_count(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> group_thousands()
  end

  defp format_count(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {number, ""} -> group_thousands(Integer.to_string(number))
      _ -> value
    end
  end

  defp format_count(value), do: to_string(value)

  defp running_table_header_row(running_event_width) do
    header =
      [
        format_cell("ID", @running_id_width),
        format_cell("STAGE", @running_stage_width),
        format_cell("PID", @running_pid_width),
        format_cell("AGE / TURN", @running_age_width),
        format_cell("TOKENS", @running_tokens_width),
        format_cell("SESSION", @running_session_width),
        format_cell("EVENT", running_event_width)
      ]
      |> Enum.join(" ")

    "│   " <> colorize(header, @ansi_gray)
  end

  defp running_table_separator_row(running_event_width) do
    separator_width =
      @running_id_width +
        @running_stage_width +
        @running_pid_width +
        @running_age_width +
        @running_tokens_width +
        @running_session_width +
        running_event_width + 6

    "│   " <> colorize(String.duplicate("─", separator_width), @ansi_gray)
  end

  defp running_event_width(terminal_columns) do
    terminal_columns = terminal_columns || terminal_columns()

    max(
      @running_event_min_width,
      terminal_columns - fixed_running_width() - @running_row_chrome_width
    )
  end

  defp fixed_running_width do
    @running_id_width +
      @running_stage_width +
      @running_pid_width +
      @running_age_width +
      @running_tokens_width +
      @running_session_width
  end

  defp terminal_columns do
    case :io.columns() do
      {:ok, columns} when is_integer(columns) and columns > 0 ->
        columns

      _ ->
        terminal_columns_from_env()
    end
  end

  defp terminal_columns_from_env do
    case System.get_env("COLUMNS") do
      nil ->
        fixed_running_width() + @running_row_chrome_width + @running_event_default_width

      value ->
        case Integer.parse(String.trim(value)) do
          {columns, ""} when columns > 0 -> columns
          _ -> @default_terminal_columns
        end
    end
  end

  defp format_cell(value, width, align \\ :left) do
    value =
      value
      |> to_string()
      |> String.replace("\n", " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> truncate_plain(width)

    case align do
      :right -> String.pad_leading(value, width)
      _ -> String.pad_trailing(value, width)
    end
  end

  defp truncate_plain(value, width) do
    if byte_size(value) <= width do
      value
    else
      String.slice(value, 0, width - 3) <> "..."
    end
  end

  defp compact_session_id(nil), do: "n/a"
  defp compact_session_id(session_id) when not is_binary(session_id), do: "n/a"

  defp compact_session_id(session_id) do
    if String.length(session_id) > 10 do
      String.slice(session_id, 0, 4) <> "..." <> String.slice(session_id, -6, 6)
    else
      session_id
    end
  end

  defp group_thousands(value) when is_binary(value) do
    sign = if String.starts_with?(value, "-"), do: "-", else: ""
    unsigned = if sign == "", do: value, else: String.slice(value, 1, String.length(value) - 1)

    unsigned
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
    |> prepend(sign)
  end

  defp prepend("", value), do: value
  defp prepend(prefix, value), do: prefix <> value

  defp in_bucket?(timestamp, bucket_start, bucket_end, true),
    do: timestamp >= bucket_start and timestamp <= bucket_end

  defp in_bucket?(timestamp, bucket_start, bucket_end, false),
    do: timestamp >= bucket_start and timestamp < bucket_end

  defp status_dot(color_code) do
    colorize("●", color_code)
  end

  defp normalize_status_lines(content) do
    content
  end

  defp closing_border, do: "╰─"

  defp colorize(value, code) do
    "#{code}#{value}#{@ansi_reset}"
  end

  defp summarize_message(message), do: AgentMessage.humanize_agent_message(message)

  defp truncate(value, max) when byte_size(value) > max do
    value |> String.slice(0, max) |> Kernel.<>("...")
  end

  defp truncate(value, _max), do: value
end

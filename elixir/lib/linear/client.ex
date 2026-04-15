defmodule Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias Linear.ResponseDecoder
  alias Schema.Tracker.Issue

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  @query """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec fetch_candidate_issues(Linear.Tracker.settings()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(settings) do
    project_slug = Map.get(settings, :project_slug)

    cond do
      is_nil(Map.get(settings, :api_key)) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter(settings) do
          do_fetch_by_states(settings, project_slug, Map.get(settings, :active_states, []), assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_states(Linear.Tracker.settings(), [String.t()]) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(settings, state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      project_slug = Map.get(settings, :project_slug)

      cond do
        is_nil(Map.get(settings, :api_key)) ->
          {:error, :missing_linear_api_token}

        is_nil(project_slug) ->
          {:error, :missing_linear_project_slug}

        true ->
          do_fetch_by_states(settings, project_slug, normalized_states, nil)
      end
    end
  end

  @doc """
  Fetch issue state for a list of issue ids, paginated.

  Options:

    * `:graphql_fun` — a 2-arity function `(query, variables) -> {:ok, body} | {:error, reason}`
      used in place of the real HTTP path. Skips assignee resolution (the viewer
      lookup requires a real endpoint) and pages through `ids` using the supplied
      fun. Used by tests that exercise pagination without hitting Linear.
  """
  @spec fetch_issue_states_by_ids(Linear.Tracker.settings(), [String.t()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(settings, issue_ids, opts \\ []) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case {ids, Keyword.get(opts, :graphql_fun)} do
      {[], _} ->
        {:ok, []}

      {ids, nil} ->
        with {:ok, assignee_filter} <- routing_assignee_filter(settings) do
          do_fetch_issue_states(settings, ids, assignee_filter)
        end

      {ids, graphql_fun} when is_function(graphql_fun, 2) ->
        do_fetch_issue_states_with_fun(ids, nil, graphql_fun)
    end
  end

  @spec graphql(Linear.Tracker.settings(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def graphql(settings, query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request(settings, &1, &2))

    with {:ok, headers} <- graphql_headers(settings),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "Linear GraphQL request failed status=#{response.status}" <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  defp do_fetch_by_states(settings, project_slug, state_names, assignee_filter) do
    do_fetch_by_states_page(settings, project_slug, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_by_states_page(settings, project_slug, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(settings, @query, %{
             projectSlug: project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- ResponseDecoder.decode_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case ResponseDecoder.next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(settings, project_slug, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(settings, ids, assignee_filter) do
    do_fetch_issue_states_with_fun(ids, assignee_filter, &graphql(settings, &1, &2))
  end

  defp do_fetch_issue_states_with_fun(ids, assignee_filter, graphql_fun)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(@query_by_ids, %{
           ids: batch_ids,
           first: length(batch_ids),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- ResponseDecoder.decode_response(body, assignee_filter) do
          updated_acc = prepend_page_issues(issues, acc_issues)
          do_fetch_issue_states_page(rest_ids, assignee_filter, graphql_fun, updated_acc, issue_order_index)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers(settings) do
    case Map.get(settings, :api_key) do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(settings, payload, headers) do
    Req.post(Map.get(settings, :endpoint),
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp routing_assignee_filter(settings) do
    case Map.get(settings, :assignee) do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(settings, assignee)
    end
  end

  defp build_assignee_filter(settings, assignee) when is_binary(assignee) do
    case ResponseDecoder.normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter(settings)

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter(settings) do
    case graphql(settings, @viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case ResponseDecoder.assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule Linear.ResponseDecoder do
  @moduledoc """
  Pure decoders that map Linear GraphQL payloads into `Schema.Tracker.Issue`
  structs and related value types. Stateless and side-effect free — all HTTP
  lives in `Linear.Client`.
  """

  alias Schema.Tracker.Issue

  @type assignee_filter :: %{configured_assignee: String.t(), match_values: MapSet.t(String.t())} | nil

  @doc """
  Decode a candidate-issues response body into `{:ok, [Issue.t()]}` or a
  typed error tuple.
  """
  @spec decode_response(map(), assignee_filter()) ::
          {:ok, [Issue.t()]}
          | {:error, {:linear_graphql_errors, list()}}
          | {:error, :linear_unknown_payload}
  def decode_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  def decode_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  def decode_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  @doc """
  Decode a paginated candidate-issues response body into
  `{:ok, [Issue.t()], %{has_next_page: boolean(), end_cursor: String.t() | nil}}`.
  """
  @spec decode_page_response(map(), assignee_filter()) ::
          {:ok, [Issue.t()], %{has_next_page: boolean(), end_cursor: String.t() | nil}}
          | {:error, term()}
  def decode_page_response(
        %{
          "data" => %{
            "issues" => %{
              "nodes" => nodes,
              "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
            }
          }
        },
        assignee_filter
      ) do
    with {:ok, issues} <- decode_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  def decode_page_response(response, assignee_filter), do: decode_response(response, assignee_filter)

  @spec next_page_cursor(%{has_next_page: boolean(), end_cursor: String.t() | nil}) ::
          {:ok, String.t()} | :done | {:error, :linear_missing_end_cursor}
  def next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
      when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  def next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  def next_page_cursor(_), do: :done

  @spec normalize_issue(map(), assignee_filter()) :: Issue.t() | nil
  def normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  def normalize_issue(_issue, _assignee_filter), do: nil

  @doc """
  Extract the `"id"` (or other named field) from an assignee object. Returns
  nil if the assignee is not a map.
  """
  @spec assignee_id(map()) :: String.t() | nil
  def assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  @doc """
  Normalize a value used to match assignees (trims whitespace, rejects empty
  strings and non-binaries). Used by both the decoder's filter application
  and the client's filter builder.
  """
  @spec normalize_assignee_match_value(term()) :: String.t() | nil
  def normalize_assignee_match_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_assignee_match_value(_value), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    case assignee_id(assignee) do
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    Enum.flat_map(inverse_relations, &decode_blocker_relation/1)
  end

  defp extract_blockers(_), do: []

  defp decode_blocker_relation(%{"type" => relation_type, "issue" => blocker_issue})
       when is_binary(relation_type) and is_map(blocker_issue) do
    if String.downcase(String.trim(relation_type)) == "blocks" do
      [
        %{
          id: blocker_issue["id"],
          identifier: blocker_issue["identifier"],
          state: get_in(blocker_issue, ["state", "name"])
        }
      ]
    else
      []
    end
  end

  defp decode_blocker_relation(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end

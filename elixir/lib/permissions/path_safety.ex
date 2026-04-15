defmodule Permissions.PathSafety do
  @moduledoc """
  Path validation guards against traversal and symlink-escape attacks.

  Pure functions over filesystem paths. No state, no Application env reads,
  no cross-boundary calls. Lives in the `Permissions` boundary alongside
  other security-sensitive helpers.
  """

  @type workspace_error ::
          {:workspace_equals_root, canonical :: Path.t(), canonical_root :: Path.t()}
          | {:symlink_escape, expanded :: Path.t(), canonical_root :: Path.t()}
          | {:outside_root, canonical :: Path.t(), canonical_root :: Path.t()}
          | {:path_unreadable, Path.t(), term()}

  @type remote_workspace_error :: :empty | :invalid_characters

  @spec canonicalize(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonicalize(path) when is_binary(path) do
    expanded_path = Path.expand(path)
    {root, segments} = split_absolute_path(expanded_path)

    case resolve_segments(root, [], segments) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, reason} ->
        {:error, {:path_canonicalize_failed, expanded_path, reason}}
    end
  end

  @doc """
  Validate that `workspace` resolves to a path inside `workspace_root`.

  Returns `{:ok, canonical_workspace}` on success. Callers map the error into
  whatever module-local tuple shape they expose to the rest of the system.
  """
  @spec validate_workspace_in_root(Path.t(), Path.t()) ::
          {:ok, canonical_workspace :: Path.t()} | {:error, workspace_error}
  def validate_workspace_in_root(workspace, workspace_root)
      when is_binary(workspace) and is_binary(workspace_root) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- canonicalize(expanded_workspace),
         {:ok, canonical_root} <- canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:path_unreadable, path, reason}}
    end
  end

  @doc """
  Validate that a remote workspace path string is non-empty and free of
  characters that would break shell command construction on the remote host.
  """
  @spec validate_remote_workspace(String.t()) :: :ok | {:error, remote_workspace_error}
  def validate_remote_workspace(workspace) when is_binary(workspace) do
    cond do
      String.trim(workspace) == "" -> {:error, :empty}
      String.contains?(workspace, ["\n", "\r", <<0>>]) -> {:error, :invalid_characters}
      true -> :ok
    end
  end

  defp split_absolute_path(path) when is_binary(path) do
    [root | segments] = Path.split(path)
    {root, segments}
  end

  defp resolve_segments(root, resolved_segments, []), do: {:ok, join_path(root, resolved_segments)}

  defp resolve_segments(root, resolved_segments, [segment | rest]) do
    candidate_path = join_path(root, resolved_segments ++ [segment])

    case File.lstat(candidate_path) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- :file.read_link_all(String.to_charlist(candidate_path)) do
          resolved_target = Path.expand(IO.chardata_to_string(target), join_path(root, resolved_segments))
          {target_root, target_segments} = split_absolute_path(resolved_target)
          resolve_segments(target_root, [], target_segments ++ rest)
        end

      {:ok, _stat} ->
        resolve_segments(root, resolved_segments ++ [segment], rest)

      {:error, :enoent} ->
        {:ok, join_path(root, resolved_segments ++ [segment | rest])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp join_path(root, segments) when is_list(segments) do
    Enum.reduce(segments, root, fn segment, acc -> Path.join(acc, segment) end)
  end
end

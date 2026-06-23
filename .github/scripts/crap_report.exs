Mix.shell(Mix.Shell.Quiet)

defmodule CrapReport do
  @threshold 30.0
  @top 25
  @source_path "lib"
  @coverdata_globs ["coverage/**/*.coverdata", "cover/*.coverdata"]
  @merged_path "cover/crap/merged.coverdata"

  def run(output) do
    root = File.cwd!()

    body =
      case coverdata_files() do
        [] -> no_coverage()
        files -> report(root, merge(root, files))
      end

    case output do
      nil -> IO.puts(body)
      path -> File.write!(path, body)
    end
  end

  defp report(root, coverdata) do
    case ExCrap.project_report(root, coverdata, source_path: @source_path) do
      {:ok, rows} ->
        scored = Enum.filter(rows, &(&1.status == :scored and is_number(&1.score)))
        kept = Enum.reject(scored, &ignored?(&1, ignore_patterns(root)))
        render(kept, length(scored) - length(kept))

      other ->
        error(other)
    end
  end

  defp coverdata_files do
    @coverdata_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
  end

  defp merge(root, files) do
    :cover.start()
    Enum.each(files, &:cover.import(String.to_charlist(&1)))

    merged = Path.join(root, @merged_path)
    File.mkdir_p!(Path.dirname(merged))
    :cover.export(String.to_charlist(merged))
    merged
  end

  defp ignore_patterns(root) do
    (coveralls_skips(root) ++ crapignore(root))
    |> Enum.map(&String.trim_leading(&1, "/"))
    |> Enum.uniq()
  end

  defp coveralls_skips(root) do
    path = Path.join(root, "coveralls.json")

    with true <- File.exists?(path),
         {:ok, %{"skip_files" => files}} <- Jason.decode(File.read!(path)) do
      files
    else
      _ -> []
    end
  end

  defp crapignore(root) do
    path = Path.join(root, ".crapignore")

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    else
      []
    end
  end

  defp ignored?(row, patterns), do: Enum.any?(patterns, &matches?(row.file, &1))

  defp matches?(file, pattern) do
    if String.contains?(pattern, "*") do
      glob = pattern |> Regex.escape() |> String.replace("\\*", ".*")
      Regex.match?(~r/\A#{glob}\z/, file)
    else
      String.starts_with?(file, pattern)
    end
  end

  defp render([], _ignored), do: heading() <> "\nNo scored functions found. Nothing to report.\n"

  defp render(rows, ignored) do
    sorted = Enum.sort_by(rows, & &1.score, :desc)
    files = rows |> Enum.map(& &1.file) |> Enum.uniq() |> length()
    worst = sorted |> hd() |> Map.get(:score)
    above = Enum.count(rows, &(&1.score > @threshold))
    top = Enum.take(sorted, @top)

    """
    #{heading()}
    CRAP = complexity² × (1 − coverage)³ + complexity. Higher means riskier to change (complex **and** under-tested). Threshold: `#{trunc(@threshold)}`.

    **Summary:** #{length(rows)} functions scored across #{files} files · worst score **#{fmt(worst)}** · #{above} above threshold#{ignored_note(ignored)}

    ### Top #{length(top)} offenders
    #{table(top)}

    <details><summary>Full table (#{length(sorted)} functions)</summary>

    #{table(sorted)}

    </details>
    """
  end

  defp heading, do: "## 🩹 CRAP Score Report\n"

  defp ignored_note(0), do: ""
  defp ignored_note(n), do: " · #{n} ignored (coveralls.json + .crapignore)"

  defp table(rows) do
    header = "| File | Function | Complexity | Coverage | CRAP |\n|---|---|---:|---:|---:|"
    header <> "\n" <> Enum.map_join(rows, "\n", &row_line/1)
  end

  defp row_line(row) do
    fun = "`#{inspect(row.module)}.#{row.function}/#{row.arity}`"
    "| #{row.file} | #{fun} | #{row.complexity} | #{fmt(row.coverage_percent)}% | #{fmt(row.score)} |"
  end

  defp fmt(number) when is_number(number), do: :erlang.float_to_binary(number * 1.0, decimals: 2)
  defp fmt(other), do: to_string(other)

  defp no_coverage do
    heading() <>
      "\nNo coverage data found (looked in #{Enum.join(@coverdata_globs, ", ")}). " <>
      "Run `mix test --cover --export-coverage default` first.\n"
  end

  defp error(reason), do: heading() <> "\nCould not build the CRAP report: `#{inspect(reason)}`.\n"
end

CrapReport.run(List.first(System.argv()))

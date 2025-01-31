%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "src/", "web/", "apps/"],
        excluded: []
      },
      plugins: [],
      requires: [],
      strict: false,
      parse_timeout: 5000,
      color: true,
      checks: %{
        disabled: [
          {Credo.Check.Design.TagTODO, []},
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Refactor.Nesting, []},
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Readability.WithSingleClause, []},
          {Credo.Check.Readability.AliasOrder, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Refactor.Apply, []}
        ]
      }
    }
  ]
}

%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/"], excluded: ["deps/", "_build/"]},
      strict: true,
      checks: %{
        extra: [
          {Credo.Check.Readability.MaxLineLength, max_length: 100}
        ],
        disabled: [
          {Credo.Check.Design.TagTODO, []}
        ]
      }
    }
  ]
}

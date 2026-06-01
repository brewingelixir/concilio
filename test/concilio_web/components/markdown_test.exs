defmodule ConcilioWeb.Components.MarkdownTest do
  use ExUnit.Case, async: true

  alias ConcilioWeb.Components.Markdown

  test "render/1 returns empty for nil" do
    assert Markdown.render(nil) == ""
  end

  test "render/1 produces html for basic markdown" do
    html = Markdown.render("**bold** and `code`")
    assert html =~ "<strong>bold</strong>"
    assert html =~ "<code"
    assert html =~ "code</code>"
  end

  test "render/1 enables GFM tables" do
    md = """
    | a | b |
    |---|---|
    | 1 | 2 |
    """

    html = Markdown.render(md)
    assert html =~ "<table>"
    assert html =~ ">1</td>"
  end

  test "render/1 turns single newlines into <br/> via :breaks" do
    html = Markdown.render("line one\nline two")
    assert html =~ "<br>"
  end
end

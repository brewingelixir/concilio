defmodule Concilio.Chats.History do
  @moduledoc """
  Flatten a list of `Concilio.Chats.Message` rows into the OpenAI-style
  `[%{role: "user" | "assistant", content: ...}]` history shape that
  plain-model completions and council inputs both consume.

  Council assistant messages persist `content: ""`; the user-facing text
  lives in the linked `runs.result_json["final"]["content"]`. This module
  hydrates that content so a plain-model follow-up turn (or a model
  switch) sees what the council actually said.
  """

  alias Concilio.Chats.{CouncilRefs, Message}
  alias Concilio.Runs.Run

  @type entry :: %{role: String.t(), content: String.t()}

  @spec build([Message.t()]) :: [entry()]
  def build(messages) when is_list(messages) do
    Enum.flat_map(messages, &message_to_entries/1)
  end

  defp message_to_entries(%Message{role: :user, content: c}) when is_binary(c) and c != "" do
    [%{role: "user", content: CouncilRefs.expand(c)}]
  end

  defp message_to_entries(%Message{role: :assistant} = msg) do
    case assistant_content(msg) do
      nil -> []
      "" -> []
      content -> [%{role: "assistant", content: content}]
    end
  end

  defp message_to_entries(_), do: []

  defp assistant_content(%Message{run: %Run{result_json: %{} = result}}) do
    case Map.get(result, "final") do
      %{"content" => content} when is_binary(content) and content != "" -> content
      _ -> nil
    end
  end

  defp assistant_content(%Message{content: c}) when is_binary(c) and c != "", do: c
  defp assistant_content(_), do: nil
end

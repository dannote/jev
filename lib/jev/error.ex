defmodule Jev.Error do
  @moduledoc """
  A non-2xx response from the TypeSafe API.

  `status` is the HTTP status, `body` the decoded JSON body (or raw text), and
  `request_id` the value of the `x-typesafe-request-id` header when present.
  """

  defexception [:status, :body, request_id: ""]

  @type t :: %__MODULE__{status: pos_integer(), body: term(), request_id: String.t()}

  @impl true
  def message(%__MODULE__{status: status, body: body, request_id: id}) do
    suffix = if id == "", do: "", else: " (request #{id})"
    "TypeSafe responded #{status}: #{describe(body)}#{suffix}"
  end

  defp describe(body) when is_binary(body), do: body

  defp describe(%{} = body) do
    case body["error"] || body["message"] || body["detail"] do
      text when is_binary(text) -> text
      %{"message" => text} when is_binary(text) -> text
      _ -> body |> JSON.encode!() |> String.slice(0, 200)
    end
  end

  defp describe(_), do: "(no body)"
end

defmodule Jev.Error do
  @moduledoc """
  A non-2xx response from a `/v1/systemone` endpoint.

  `status` is the HTTP status, `body` the decoded JSON body (or raw text),
  `request_id` the value of the `x-typesafe-request-id` header when present,
  and `endpoint` the name of the endpoint that answered.
  """

  defexception [:status, :body, request_id: "", endpoint: :typesafe]

  @type t :: %__MODULE__{
          status: pos_integer(),
          body: term(),
          request_id: String.t(),
          endpoint: atom()
        }

  @impl true
  def message(%__MODULE__{status: status, body: body, request_id: id, endpoint: endpoint}) do
    suffix = if id == "", do: "", else: " (request #{id})"
    "#{who(endpoint)} responded #{status}: #{describe(body)}#{suffix}"
  end

  defp who(:typesafe), do: "TypeSafe"
  defp who(endpoint), do: "endpoint #{inspect(endpoint)}"

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

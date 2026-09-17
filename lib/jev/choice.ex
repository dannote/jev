defmodule Jev.Choice do
  @moduledoc """
  Pick one of 2 to 255 labelled options. Jev answers with the label as an atom,
  plus a confidence and the probability of every option.

  Labels are atoms; descriptions are text, a JSON-encodable map, or `nil`:

      %Jev.Choice{
        instructions: "What kind of issue is this?",
        criteria: %{bug: "Something is broken", feature: "Request for new behavior", other: nil}
      }
  """

  @derive JSON.Encoder
  defstruct type: :choice, instructions: nil, criteria: %{}

  @type t :: %__MODULE__{
          type: :choice,
          instructions: Jev.entry(),
          criteria: %{atom() => Jev.entry()}
        }
end

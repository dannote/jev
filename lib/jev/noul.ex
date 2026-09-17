defmodule Jev.Noul do
  @moduledoc """
  A yes/no question. Jev answers with the probability of yes, from 0 to 1.

  `instructions` is text or a JSON-encodable map. `criteria` optionally
  describes what counts as true and false:

      %Jev.Noul{
        instructions: "Does this need immediate attention?",
        criteria: %{true: "Users cannot use the service.", false: "A workaround exists."}
      }
  """

  @derive JSON.Encoder
  defstruct type: :noul, instructions: nil, criteria: nil

  @type t :: %__MODULE__{
          type: :noul,
          instructions: Jev.entry(),
          criteria: %{optional(true) => Jev.entry(), optional(false) => Jev.entry()} | nil
        }
end

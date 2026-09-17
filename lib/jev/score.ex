defmodule Jev.Score do
  @moduledoc """
  Rate the state on 2 to 10 ordered levels, numbered from 0. Jev answers with the
  expected level as a float, plus a confidence and the probability of every level.

      %Jev.Score{
        instructions: "How severe is this issue for users?",
        criteria: ["Cosmetic", "Workaround exists", "Blocks a common use case", "Data loss"]
      }
  """

  @derive JSON.Encoder
  defstruct type: :score, instructions: nil, criteria: []

  @type t :: %__MODULE__{
          type: :score,
          instructions: Jev.entry(),
          criteria: [Jev.entry(), ...]
        }
end

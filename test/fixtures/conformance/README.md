# Conformance fixtures

Response bodies recorded from running `/v1/systemone` servers, decoded by
`Jev.ConformanceTest`. The questions are the ones in that test.

| File | Server | Recorded |
| --- | --- | --- |
| `jeff.json` | [jeff](https://github.com/logan-markewich/jeff) 0.1.0, GLiFormer large, local | 2026-09-22 |

To add one, point `examples/local.exs` at the server, then save the body of a
`POST /v1/systemone` with the same questions.

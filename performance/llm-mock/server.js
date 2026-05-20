'use strict';

const express = require('express');

const app = express();
app.use(express.json({ limit: '10mb' }));

const DELAY_MS = parseInt(process.env.LLM_MOCK_DELAY_MS ?? '800', 10);
const PORT     = parseInt(process.env.PORT ?? '9999', 10);

// Rotate through deterministic replies so the LLM "says something different".
// conversation-chat calls the LLM with response_format=json_object and expects
// the content field to be a JSON string matching its structured schema:
//   { "action": "none|tool_call|escalate|close_session",
//     "message": { "text": "...", "escalation": null, "tool": null } }
// Plain-text content causes json.Unmarshal to fail inside conversation-chat,
// producing the "Lo siento, ocurrió un error" fallback.
//
// chat-orch (Rust/llm.rs) uses the same /v1/chat/completions endpoint but reads
// choices[0].message.content as plain text — it also accepts the JSON string
// and simply renders it verbatim, which is acceptable for perf tests.
const REPLY_TEXTS = [
  'Hola, soy el asistente del Hospital UNAgent. ¿En qué le puedo ayudar hoy?',
  '¿Cuál es su nombre y número de identificación para continuar?',
  'Entendido. ¿Tiene preferencia por alguna especialidad médica o doctor?',
  'Permítame verificar la disponibilidad de citas para esa fecha.',
  'La cita ha sido agendada exitosamente. Le enviaremos la confirmación.',
];

let counter = 0;

// ──────────────────────────────────────────────────────────────────────────────
// POST /v1/chat/completions  — OpenAI-compatible, structured-JSON content.
// ──────────────────────────────────────────────────────────────────────────────
app.post('/v1/chat/completions', async (req, res) => {
  await new Promise((resolve) => setTimeout(resolve, DELAY_MS));

  const text = REPLY_TEXTS[counter++ % REPLY_TEXTS.length];

  // Content is the JSON structure conversation-chat expects.
  const content = JSON.stringify({
    action: 'none',
    message: { text, escalation: null, tool: null },
  });

  res.json({
    id: `chatcmpl-mock-${Date.now()}`,
    object: 'chat.completion',
    created: Math.floor(Date.now() / 1000),
    model: req.body?.model ?? 'mock-llm-perf',
    choices: [
      {
        index: 0,
        message: {
          role: 'assistant',
          content,
          tool_calls: null,
        },
        finish_reason: 'stop',
        logprobs: null,
      },
    ],
    usage: {
      prompt_tokens: 120,
      completion_tokens: 25,
      total_tokens: 145,
    },
  });
});

app.get('/health', (_req, res) =>
  res.json({ status: 'ok', delay_ms: DELAY_MS, requests_served: counter }),
);

app.listen(PORT, '0.0.0.0', () =>
  console.log(
    JSON.stringify({ level: 'info', msg: 'llm-mock ready', port: PORT, delay_ms: DELAY_MS }),
  ),
);

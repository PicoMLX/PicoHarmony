use std::collections::HashSet;
use std::str::FromStr;
use std::sync::{Arc, Mutex};

use openai_harmony::chat::{Content, Message, Role};
use openai_harmony::{
    load_harmony_encoding, HarmonyEncoding, HarmonyEncodingName, ParseOptions, RenderConversationConfig,
    RenderOptions, StreamableParser,
};
use serde_json;
use thiserror::Error;

uniffi::setup_scaffolding!();

#[derive(Debug, Error, uniffi::Error)]
pub enum PicoHarmonyError {
    #[error("{0}")]
    Msg(String),
}

fn err<T: ToString>(t: T) -> PicoHarmonyError {
    PicoHarmonyError::Msg(t.to_string())
}

#[derive(uniffi::Record)]
pub struct ParsedAssistant {
    pub reasoning: Option<String>,
    pub final_text: Option<String>,
}

#[derive(uniffi::Record)]
pub struct StreamDelta {
    pub channel: Option<String>,
    pub delta: Option<String>,
    pub content_type: Option<String>,
    pub recipient: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct RenderConversationConfigFfi {
    pub auto_drop_analysis: bool,
}

impl From<&RenderConversationConfigFfi> for RenderConversationConfig {
    fn from(cfg: &RenderConversationConfigFfi) -> Self {
        RenderConversationConfig {
            auto_drop_analysis: cfg.auto_drop_analysis,
        }
    }
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct RenderOptionsFfi {
    pub conversation_has_function_tools: bool,
}

impl From<&RenderOptionsFfi> for RenderOptions {
    fn from(opts: &RenderOptionsFfi) -> Self {
        RenderOptions {
            conversation_has_function_tools: opts.conversation_has_function_tools,
        }
    }
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct ParsedMessagesJson {
    pub messages_json: String,
}


#[derive(uniffi::Object)]
pub struct PicoHarmonyGptOss {
    enc: Arc<HarmonyEncoding>,
}

#[uniffi::export]
impl PicoHarmonyGptOss {
    #[uniffi::constructor]
    pub fn new() -> Result<Self, PicoHarmonyError> {
        let enc = load_harmony_encoding(HarmonyEncodingName::HarmonyGptOss).map_err(err)?;
        Ok(Self { enc: Arc::new(enc) })
    }

    /// Batch parse: pass all completion token IDs.
    pub fn parse_completion_tokens(
        &self,
        token_ids: Vec<u32>,
    ) -> Result<ParsedAssistant, PicoHarmonyError> {
        let msgs = self
            .enc
            .parse_messages_from_completion_tokens(token_ids, Some(Role::Assistant))
            .map_err(err)?;

        Ok(extract_reasoning_final(&msgs))
    }

    /// Streaming parse: returns an object you can feed tokens into.
    pub fn new_stream_parser(&self) -> Result<PicoHarmonyStreamParser, PicoHarmonyError> {
        let p = StreamableParser::new((*self.enc).clone(), Some(Role::Assistant)).map_err(err)?;
        Ok(PicoHarmonyStreamParser {
            inner: Mutex::new(Some(p)),
        })
    }
}

#[uniffi::export]
impl HarmonyEncodingFfi {
    #[uniffi::constructor]
    pub fn new(name: String) -> Result<Self, PicoHarmonyError> {
        let parsed = HarmonyEncodingName::from_str(name.as_str())
            .map_err(|_| err("unknown encoding name"))?;
        let enc = load_harmony_encoding(parsed).map_err(err)?;
        Ok(Self {
            enc: Arc::new(enc),
        })
    }

    pub fn name(&self) -> String {
        self.enc.name().to_string()
    }

    pub fn special_tokens(&self) -> Vec<String> {
        self.enc
            .tokenizer()
            .special_tokens()
            .into_iter()
            .map(str::to_string)
            .collect()
    }

    pub fn render_conversation_for_completion(
        &self,
        conversation_json: String,
        next_turn_role: String,
        config: Option<RenderConversationConfigFfi>,
    ) -> Result<Vec<u32>, PicoHarmonyError> {
        let convo: openai_harmony::chat::Conversation =
            serde_json::from_str(&conversation_json).map_err(err)?;
        let role = Role::try_from(next_turn_role.as_str()).map_err(err)?;
        let cfg = config.as_ref().map(RenderConversationConfig::from);
        self.enc
            .render_conversation_for_completion(&convo.messages, role, cfg.as_ref())
            .map_err(err)
    }

    pub fn render_conversation(
        &self,
        conversation_json: String,
        config: Option<RenderConversationConfigFfi>,
    ) -> Result<Vec<u32>, PicoHarmonyError> {
        let convo: openai_harmony::chat::Conversation =
            serde_json::from_str(&conversation_json).map_err(err)?;
        let cfg = config.as_ref().map(RenderConversationConfig::from);
        self.enc
            .render_conversation(&convo.messages, cfg.as_ref())
            .map_err(err)
    }

    pub fn render_conversation_for_training(
        &self,
        conversation_json: String,
        config: Option<RenderConversationConfigFfi>,
    ) -> Result<Vec<u32>, PicoHarmonyError> {
        let convo: openai_harmony::chat::Conversation =
            serde_json::from_str(&conversation_json).map_err(err)?;
        let cfg = config.as_ref().map(RenderConversationConfig::from);
        self.enc
            .render_conversation_for_training(&convo.messages, cfg.as_ref())
            .map_err(err)
    }

    pub fn render(
        &self,
        message_json: String,
        render_options: Option<RenderOptionsFfi>,
    ) -> Result<Vec<u32>, PicoHarmonyError> {
        let message: Message = serde_json::from_str(&message_json).map_err(err)?;
        let opts = render_options.as_ref().map(RenderOptions::from);
        self.enc.render(&message, opts.as_ref()).map_err(err)
    }

    pub fn parse_messages_from_completion_tokens(
        &self,
        tokens: Vec<u32>,
        role: Option<String>,
        strict: bool,
    ) -> Result<String, PicoHarmonyError> {
        let parsed_role = match role {
            Some(r) => Some(Role::try_from(r.as_str()).map_err(err)?),
            None => None,
        };
        let _ = strict; // current parser always strict; kept for API parity
        let msgs = self
            .enc
            .parse_messages_from_completion_tokens(tokens, parsed_role)
            .map_err(err)?;
        serde_json::to_string(&msgs).map_err(err)
    }

    pub fn decode_utf8(&self, tokens: Vec<u32>) -> Result<String, PicoHarmonyError> {
        self.enc
            .tokenizer()
            .decode_utf8(tokens)
            .map_err(err)
    }

    pub fn decode_bytes(
        &self,
        tokens: Vec<u32>,
        errors: String,
    ) -> Result<String, PicoHarmonyError> {
        let data = self
            .enc
            .tokenizer()
            .decode_bytes(tokens)
            .map_err(err)?;
        if errors == "strict" {
            String::from_utf8(data).map_err(err)
        } else {
            Ok(String::from_utf8_lossy(&data).to_string())
        }
    }

    pub fn encode(
        &self,
        text: String,
        allowed_special: Vec<String>,
    ) -> Result<Vec<u32>, PicoHarmonyError> {
        let allowed_set: HashSet<&str> = allowed_special.iter().map(|s| s.as_str()).collect();
        Ok(self.enc.tokenizer().encode(&text, &allowed_set).0)
    }

    pub fn is_special_token(&self, token: u32) -> bool {
        self.enc.tokenizer().is_special_token(token)
    }

    pub fn stop_tokens(&self) -> Result<Vec<u32>, PicoHarmonyError> {
        self.enc
            .stop_tokens()
            .map(|s| s.into_iter().collect())
            .map_err(err)
    }

    pub fn stop_tokens_for_assistant_actions(&self) -> Result<Vec<u32>, PicoHarmonyError> {
        self.enc
            .stop_tokens_for_assistant_actions()
            .map(|s| s.into_iter().collect())
            .map_err(err)
    }

    pub fn new_stream_parser(
        &self,
        role: Option<String>,
        strict: bool,
    ) -> Result<PicoHarmonyStreamParser, PicoHarmonyError> {
        let parsed_role = match role {
            Some(r) => Some(Role::try_from(r.as_str()).map_err(err)?),
            None => None,
        };
        let opts = ParseOptions { strict };
        let p = StreamableParser::new_with_options((*self.enc).clone(), parsed_role, opts)
            .map_err(err)?;
        Ok(PicoHarmonyStreamParser {
            inner: Mutex::new(Some(p)),
        })
    }
}

#[uniffi::export]
pub fn load_harmony_encoding_ffi(name: String) -> Result<HarmonyEncodingFfi, PicoHarmonyError> {
    HarmonyEncodingFfi::new(name)
}

#[derive(uniffi::Object)]
pub struct PicoHarmonyStreamParser {
    // Interior mutability so UniFFI can keep the object behind Arc.
    inner: Mutex<Option<StreamableParser>>,
}

#[derive(uniffi::Object)]
pub struct HarmonyEncodingFfi {
    enc: Arc<HarmonyEncoding>,
}

#[uniffi::export]
impl PicoHarmonyStreamParser {
    /// Feed one token id; returns the delta (if any) plus channel metadata.
    pub fn process(&self, token_id: u32) -> Result<StreamDelta, PicoHarmonyError> {
        let mut guard = self.inner.lock().map_err(|_| err("mutex poisoned"))?;
        let p = guard.as_mut().ok_or_else(|| err("parser already finished"))?;

        p.process(token_id).map_err(err)?;
        let delta = p.last_content_delta().map_err(err)?;

        Ok(StreamDelta {
            channel: p.current_channel(),
            delta,
            content_type: p.current_content_type(),
            recipient: p.current_recipient(),
        })
    }

    pub fn process_eos(&self) -> Result<(), PicoHarmonyError> {
        let mut guard = self.inner.lock().map_err(|_| err("mutex poisoned"))?;
        let p = guard.as_mut().ok_or_else(|| err("parser already finished"))?;
        p.process_eos().map_err(err)?;
        Ok(())
    }

    /// Finish parsing. Can be called once; subsequent calls error.
    pub fn finish(&self) -> Result<ParsedAssistant, PicoHarmonyError> {
        let mut guard = self.inner.lock().map_err(|_| err("mutex poisoned"))?;
        let p = guard.take().ok_or_else(|| err("parser already finished"))?;
        let msgs = p.into_messages();
        Ok(extract_reasoning_final(&msgs))
    }

    pub fn current_content(&self) -> Result<String, PicoHarmonyError> {
        let guard = self.inner.lock().map_err(|_| err("mutex poisoned"))?;
        let p = guard.as_ref().ok_or_else(|| err("parser already finished"))?;
        p.current_content().map_err(err)
    }

    pub fn current_role(&self) -> Result<Option<String>, PicoHarmonyError> {
        let guard = self.inner.lock().map_err(|_| err("mutex poisoned"))?;
        let p = guard.as_ref().ok_or_else(|| err("parser already finished"))?;
        Ok(p.current_role().map(|r| r.as_str().to_string()))
    }

    pub fn current_content_type(&self) -> Result<Option<String>, PicoHarmonyError> {
        let guard = self.inner.lock().map_err(|_| err("mutex poisoned"))?;
        let p = guard.as_ref().ok_or_else(|| err("parser already finished"))?;
        Ok(p.current_content_type())
    }

    pub fn last_content_delta(&self) -> Result<Option<String>, PicoHarmonyError> {
        let guard = self.inner.lock().map_err(|_| err("mutex poisoned"))?;
        let p = guard.as_ref().ok_or_else(|| err("parser already finished"))?;
        p.last_content_delta().map_err(err)
    }

    pub fn messages_json(&self) -> Result<String, PicoHarmonyError> {
        let guard = self.inner.lock().map_err(|_| err("mutex poisoned"))?;
        let p = guard.as_ref().ok_or_else(|| err("parser already finished"))?;
        let msgs = p.messages();
        serde_json::to_string(&msgs).map_err(err)
    }

    pub fn tokens(&self) -> Result<Vec<u32>, PicoHarmonyError> {
        let guard = self.inner.lock().map_err(|_| err("mutex poisoned"))?;
        let p = guard.as_ref().ok_or_else(|| err("parser already finished"))?;
        Ok(p.tokens().to_vec())
    }

    pub fn state_json(&self) -> Result<String, PicoHarmonyError> {
        let guard = self.inner.lock().map_err(|_| err("mutex poisoned"))?;
        let p = guard.as_ref().ok_or_else(|| err("parser already finished"))?;
        p.state_json().map_err(err)
    }

    pub fn current_recipient(&self) -> Result<Option<String>, PicoHarmonyError> {
        let guard = self.inner.lock().map_err(|_| err("mutex poisoned"))?;
        let p = guard.as_ref().ok_or_else(|| err("parser already finished"))?;
        Ok(p.current_recipient())
    }

    pub fn current_channel(&self) -> Result<Option<String>, PicoHarmonyError> {
        let guard = self.inner.lock().map_err(|_| err("mutex poisoned"))?;
        let p = guard.as_ref().ok_or_else(|| err("parser already finished"))?;
        Ok(p.current_channel())
    }
}

fn extract_reasoning_final(msgs: &[Message]) -> ParsedAssistant {
    let mut reasoning = String::new();
    let mut final_text = String::new();

    for m in msgs {
        let channel = m.channel.as_deref().unwrap_or("");
        let mut text = String::new();

        for c in &m.content {
            if let Content::Text(t) = c {
                text.push_str(&t.text);
            }
        }

        match channel {
            "analysis" => reasoning.push_str(&text),
            "final" => final_text.push_str(&text),
            _ => {}
        }
    }

    ParsedAssistant {
        reasoning: if reasoning.is_empty() { None } else { Some(reasoning) },
        final_text: if final_text.is_empty() { None } else { Some(final_text) },
    }
}

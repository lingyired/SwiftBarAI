// AIGeneratorTemplate.swift
// menubar01 — AI Plugin Generator (M2+ template gallery)
//
// Pre-made prompts the user can one-click load into the M2 generator
// sheet's request field. Picking a template pre-fills the request text
// but does NOT auto-generate — the user is expected to review and
// tweak the prompt before clicking "Generate". This is a small UX
// win that makes the M2 sheet feel more like a product: the user
// does not have to think of a prompt from scratch, and the gallery
// doubles as a "what can I generate?" catalogue.
//
// The gallery is a static `enum` (not a class or struct) so callers
// can reach the templates as `AIGeneratorTemplateGallery.templates`
// without having to instantiate anything. The list is append-only —
// renaming or removing a template is a breaking change for anyone
// who has bookmarked one (the v1 contract is "the gallery is a
// stable catalogue"). Adding a new template is non-breaking and
// just bumps the gallery's `count`.
//
// All members are `public` and `Sendable` so the templates can be
// used from any actor (the sheet is `@MainActor`, but the model is
// also reachable from background tasks that just need to read
// `prompt` to seed a request string).

import Foundation

/// A pre-made prompt the user can one-click load into the M2
/// generator's request field.
///
/// v1: each template is a static, value-typed record. The
/// `systemImageName` is a SF Symbol (macOS 12+) so the gallery UI
/// can render a large icon next to the title without bundling
/// per-template image assets.
public struct AIGeneratorTemplate: Identifiable, Hashable, Sendable {
    /// Stable identifier. Used as the `id` for SwiftUI
    /// `List` / `ForEach` and as the bookmark key. **Never
    /// reuse an `id`** — append-only is the v1 contract (see
    /// `AIGeneratorTemplateGallery`).
    public let id: String

    /// Short, human-readable title shown on the card.
    public let title: String

    /// One-sentence description shown under the title in a
    /// smaller, secondary font. Should fit on one line at the
    /// default card width (200 points).
    public let description: String

    /// The natural-language prompt that gets loaded into the
    /// generator's request field when the user taps the card.
    /// Should be self-contained — the LLM has no other context
    /// beyond the sheet's `AIGeneratorContext`.
    public let prompt: String

    /// SF Symbol name for the card's icon. Must be available
    /// in macOS 12+. The full set of v1 symbols is documented
    /// in the gallery enum.
    public let systemImageName: String

    public init(
        id: String,
        title: String,
        description: String,
        prompt: String,
        systemImageName: String
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.prompt = prompt
        self.systemImageName = systemImageName
    }
}

/// The v1 gallery. Append-only — renaming or removing a template
/// is a breaking change for anyone who has bookmarked one.
///
/// The 6 v1 templates are picked to be **realistic, ship-quality
/// prompts** a user might type today. Each one is phrased so the
/// LLM can answer in a single round-trip — no follow-up
/// clarifications required. The prompts are intentionally short
/// (1–2 sentences) so the user can read them at a glance and
/// decide whether to ship as-is or tweak before clicking
/// "Generate".
public enum AIGeneratorTemplateGallery {
    /// The full v1 gallery. Order matters: the SwiftUI
    /// `LazyHStack` renders left-to-right, so the most
    /// generally-useful templates come first.
    public static let templates: [AIGeneratorTemplate] = [
        .init(
            id: "weather",
            title: "Weather",
            description: "Current weather for a city you choose.",
            prompt: "Create a plugin that shows the current weather for a city, including temperature, conditions, and a relevant emoji. Refresh every 30 minutes.",
            systemImageName: "cloud.sun"
        ),
        .init(
            id: "battery",
            title: "Battery",
            description: "Laptop battery percentage and charging status.",
            prompt: "Create a plugin that shows the laptop's battery percentage, charging state, and time remaining. Use pmset on macOS.",
            systemImageName: "battery.100"
        ),
        .init(
            id: "stock",
            title: "Stock price",
            description: "Current price for a stock ticker you choose.",
            prompt: "Create a plugin that shows the current price of a stock ticker the user provides, with daily change. Use a free public API like Yahoo Finance.",
            systemImageName: "chart.line.uptrend.xyaxis"
        ),
        .init(
            id: "hackernews",
            title: "Hacker News",
            description: "Top 5 stories from Hacker News.",
            prompt: "Create a plugin that shows the top 5 stories from Hacker News with title, score, and link. Refresh every 10 minutes.",
            systemImageName: "newspaper"
        ),
        .init(
            id: "calendar",
            title: "Calendar",
            description: "Today's calendar events.",
            prompt: "Create a plugin that shows the user's calendar events for today using AppleScript and EventKit. Refresh every 5 minutes.",
            systemImageName: "calendar"
        ),
        .init(
            id: "docker",
            title: "Docker",
            description: "Running Docker containers with status and ports.",
            prompt: "Create a plugin that lists running Docker containers with their status, image, and exposed ports. Run `docker ps` and parse the output.",
            systemImageName: "shippingbox"
        ),
    ]
}

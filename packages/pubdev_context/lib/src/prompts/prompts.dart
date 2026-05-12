/// Prompt handlers for pubdev_context guided workflows.
///
/// Two prompts are registered:
///   - evaluate_package       — guided evaluation for a named package + use case
///   - select_package_for_task — guided selection from a task description
///
/// Each returns a GetPromptResult with a PromptMessage sequence that directs
/// the LLM through a defined tool call sequence.
/// See issue #12.
library;

// TODO(#12): implement evaluate_package and select_package_for_task prompts

from python.helpers.extension import Extension
from agent import Agent, LoopData, HandledException
from python.helpers.print_style import PrintStyle
import python.helpers.log as Log

# --- Configuration ---
MAX_ITERATIONS = 25                # Hard stop after this many iterations
MAX_NO_TOOL_STREAK = 5             # Stop after this many consecutive iterations with no tool call
SIMILARITY_THRESHOLD = 0.85        # Word-level Jaccard similarity ratio for near-duplicate detection
MAX_SIMILAR_STREAK = 3             # Stop after this many near-duplicate responses in a row

# --- Data keys (prefixed to avoid collisions) ---
DATA_NO_TOOL_STREAK = "_cb_no_tool_streak"
DATA_SIMILAR_STREAK = "_cb_similar_streak"
DATA_LAST_RESPONSES = "_cb_last_responses"


class CircuitBreaker(Extension):
    async def execute(self, loop_data: LoopData = LoopData(), **kwargs):
        iteration = loop_data.iteration

        # --- Check 1: Hard iteration limit ---
        if iteration >= MAX_ITERATIONS:
            await self._trip(
                f"Circuit breaker: hit {MAX_ITERATIONS} iterations without completing. "
                f"Terminating to prevent infinite loop.",
                force_kill=True,
            )

        # --- Check 2: Consecutive iterations with no tool call ---
        if loop_data.current_tool is None:
            streak = (self.agent.get_data(DATA_NO_TOOL_STREAK) or 0) + 1
            self.agent.set_data(DATA_NO_TOOL_STREAK, streak)
            if streak >= MAX_NO_TOOL_STREAK:
                await self._trip(
                    f"Circuit breaker: {MAX_NO_TOOL_STREAK} consecutive iterations "
                    f"without a tool call. Agent appears stuck in a reasoning loop."
                )
        else:
            self.agent.set_data(DATA_NO_TOOL_STREAK, 0)  # reset on successful tool call

        # --- Check 3: Near-duplicate response detection ---
        current = loop_data.last_response
        if current:
            last_responses: list[str] = self.agent.get_data(DATA_LAST_RESPONSES) or []
            similar_streak = self.agent.get_data(DATA_SIMILAR_STREAK) or 0

            if last_responses and self._is_similar(current, last_responses[-1]):
                similar_streak += 1
            else:
                similar_streak = 0

            self.agent.set_data(DATA_SIMILAR_STREAK, similar_streak)

            # Keep a sliding window of last 5 responses
            last_responses.append(current)
            if len(last_responses) > 5:
                last_responses.pop(0)
            self.agent.set_data(DATA_LAST_RESPONSES, last_responses)

            if similar_streak >= MAX_SIMILAR_STREAK:
                await self._trip(
                    f"Circuit breaker: {MAX_SIMILAR_STREAK} consecutive near-duplicate "
                    f"responses detected. Agent is generating repetitive content."
                )

    def _is_similar(self, a: str, b: str) -> bool:
        """Fast similarity check using word-level Jaccard index.
        Catches the planning-loop pattern where 90%+ of the text is
        identical between iterations, even when not byte-for-byte equal."""
        if not a or not b:
            return False

        # Normalize: lowercase, collapse whitespace
        a_norm = " ".join(a.lower().split())
        b_norm = " ".join(b.lower().split())

        # Quick length check — if one is 2x+ the other, not similar
        if len(a_norm) > 2 * len(b_norm) or len(b_norm) > 2 * len(a_norm):
            return False

        # Word-level Jaccard similarity
        words_a = set(a_norm.split())
        words_b = set(b_norm.split())
        if not words_a or not words_b:
            return False

        intersection = len(words_a & words_b)
        union = len(words_a | words_b)
        similarity = intersection / union

        return similarity >= SIMILARITY_THRESHOLD

    async def _trip(self, reason: str, force_kill: bool = False):
        """Trip the circuit breaker: log the reason and force the agent to respond."""
        PrintStyle(font_color="red", bold=True, padding=True).print(reason)
        self.agent.context.log.log(
            type="warning", heading="Circuit Breaker", content=reason
        )

        if force_kill:
            # Past the hard limit — don't give the LLM another chance
            error_response = (
                "I was unable to complete this task. My execution loop hit "
                "the safety limit. Here is what I gathered before stopping:\n\n"
                f"Iterations completed: {self.agent.loop_data.iteration}\n"
                f"Reason: {reason}"
            )
            self.agent.hist_add_ai_response(error_response)
            self.agent.context.log.log(
                type="response",
                heading=f"{self.agent.agent_name}: Circuit breaker forced stop",
                content=error_response,
            )
            raise HandledException(reason)
        else:
            # Give the LLM one more chance with a forceful instruction
            bail_message = (
                "SYSTEM OVERRIDE: You have been running in a loop without producing "
                "a result. You must call the 'response' tool NOW with whatever output "
                "you have so far. Do not plan, do not describe what you will do. Call "
                "the response tool immediately with a summary of what you accomplished "
                "and what remains incomplete."
            )
            self.agent.hist_add_warning(bail_message)

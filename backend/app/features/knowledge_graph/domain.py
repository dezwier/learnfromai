from __future__ import annotations

from uuid import UUID

EDGE_TYPES = frozenset({"contains", "prerequisite", "related"})
DIRECTED_TYPES = frozenset({"contains", "prerequisite"})


def creates_cycle(outgoing: dict[UUID, set[UUID]], source: UUID, target: UUID) -> bool:
    """True when adding source -> target would loop back to source."""
    if source == target:
        return True
    seen: set[UUID] = set()
    stack = [target]
    while stack:
        node = stack.pop()
        if node == source:
            return True
        if node in seen:
            continue
        seen.add(node)
        stack.extend(outgoing.get(node, ()))
    return False

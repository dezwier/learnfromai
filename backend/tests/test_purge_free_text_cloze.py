"""Purge legacy free-text cloze bits; keep packs with ≥1 playable check."""

from sqlmodel import select

from app.features.content.models import KnowledgeBit
from app.features.content.purge_free_text_cloze import purge_free_text_cloze
from app.features.content.service import is_pack_complete, missing_content_kinds
from app.features.knowledge_graph.node_models import KnowledgeNode


def _add_bit(session, node_id, *, pack_index, kind, body, position=0):
    session.add(
        KnowledgeBit(
            node_id=node_id,
            pack_index=pack_index,
            kind=kind,
            band="default",
            recipe_version=1,
            position=position,
            body=body,
        )
    )


def test_purge_removes_free_text_cloze_keeps_mc(session):
    node = KnowledgeNode(name="N", name_key="n-purge", description="x")
    session.add(node)
    session.flush()
    _add_bit(
        session,
        node.id,
        pack_index=1,
        kind="learn",
        body={"title": "T", "markdown": "Body"},
        position=0,
    )
    _add_bit(
        session,
        node.id,
        pack_index=1,
        kind="check1",
        body={
            "type": "mc",
            "question": "Q?",
            "choices": ["A", "B", "C", "D"],
            "answer_index": 0,
        },
        position=1,
    )
    _add_bit(
        session,
        node.id,
        pack_index=1,
        kind="check3",
        body={
            "type": "cloze",
            "prompt": "Fill ___",
            "answer": "word",
            "aliases": ["w"],
        },
        position=3,
    )
    session.commit()

    stats = purge_free_text_cloze(session)
    session.commit()
    assert stats["cloze_bits_deleted"] == 1
    assert stats["packs_deleted"] == 0

    remaining = list(
        session.exec(select(KnowledgeBit).where(KnowledgeBit.node_id == node.id)).all()
    )
    kinds = {row.kind for row in remaining}
    assert kinds == {"learn", "check1"}
    assert is_pack_complete(session, node.id, pack_index=1)


def test_purge_deletes_pack_when_only_free_text_cloze_left(session):
    node = KnowledgeNode(name="N2", name_key="n-purge-2", description="x")
    session.add(node)
    session.flush()
    _add_bit(
        session,
        node.id,
        pack_index=1,
        kind="learn",
        body={"title": "T", "markdown": "Body"},
    )
    _add_bit(
        session,
        node.id,
        pack_index=1,
        kind="check2",
        body={"type": "cloze", "prompt": "Only ___", "answer": "x"},
        position=1,
    )
    session.commit()

    stats = purge_free_text_cloze(session)
    session.commit()
    assert stats["cloze_bits_deleted"] == 1
    assert stats["packs_deleted"] == 1
    left = list(
        session.exec(select(KnowledgeBit).where(KnowledgeBit.node_id == node.id)).all()
    )
    assert left == []


def test_pack_complete_with_single_check(session):
    node = KnowledgeNode(name="N3", name_key="n-purge-3", description="x")
    session.add(node)
    session.flush()
    _add_bit(
        session,
        node.id,
        pack_index=1,
        kind="learn",
        body={"title": "T", "markdown": "Body"},
    )
    _add_bit(
        session,
        node.id,
        pack_index=1,
        kind="check2",
        body={
            "type": "true_false",
            "statement": "Yes.",
            "answer": True,
        },
        position=1,
    )
    session.commit()
    assert missing_content_kinds(session, node.id, pack_index=1) == []
    assert is_pack_complete(session, node.id, pack_index=1)

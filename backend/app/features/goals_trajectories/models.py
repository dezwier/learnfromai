from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime, Index
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel

from app.core.time import utcnow


class LearningGoal(SQLModel, table=True):
    __tablename__ = "learning_goals"
    __table_args__ = (Index("ix_learning_goals_user_status", "user_id", "status"),)

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = Field(foreign_key="users.id", index=True)
    title: str
    topic: str
    purpose: str = ""
    language: str = "en"
    target_outcomes: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    time_budget_minutes_week: int = 180
    target_depth: str = "professional"
    status: str = "preparing"
    priority: int = 0
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class GoalGraph(SQLModel, table=True):
    __tablename__ = "goal_graphs"

    goal_id: UUID = Field(foreign_key="learning_goals.id", primary_key=True)
    graph_id: UUID = Field(foreign_key="graphs.id", primary_key=True)
    release_id: UUID | None = Field(default=None, foreign_key="graph_releases.id")
    overlay_id: UUID | None = Field(default=None, foreign_key="graph_overlays.id")


class Trajectory(SQLModel, table=True):
    __tablename__ = "trajectories"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    goal_id: UUID = Field(foreign_key="learning_goals.id", index=True)
    version: int
    planner_version: str
    reason: str = ""
    generated_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class TrajectoryRelease(SQLModel, table=True):
    __tablename__ = "trajectory_releases"

    trajectory_id: UUID = Field(foreign_key="trajectories.id", primary_key=True)
    graph_id: UUID = Field(foreign_key="graphs.id", primary_key=True)
    release_id: UUID = Field(foreign_key="graph_releases.id")


class TrajectoryStep(SQLModel, table=True):
    __tablename__ = "trajectory_steps"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    trajectory_id: UUID = Field(foreign_key="trajectories.id", index=True)
    concept_id: UUID = Field(foreign_key="concepts.id")
    objective_id: UUID = Field(foreign_key="learning_objectives.id")
    step_type: str
    rank: int
    status: str = "pending"
    rationale: str = ""
    estimated_minutes: int = 12

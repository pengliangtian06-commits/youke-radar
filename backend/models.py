from datetime import datetime, timedelta, timezone
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator

TZ = timezone(timedelta(hours=8))
FIELDS = ('course', 'title', 'due_at', 'submission', 'requirements')


def aware(value: datetime) -> datetime:
    return value.replace(tzinfo=TZ) if value.tzinfo is None else value.astimezone(TZ)


class Evidence(BaseModel):
    field: Literal['course', 'title', 'due_at', 'submission', 'requirements', 'is_update']
    quote: str = Field(min_length=1, max_length=4000)
    page: int = Field(default=1, ge=1)
    material_id: str | None = None


class ExtractedTask(BaseModel):
    course: str = Field(default='', max_length=200)
    title: str = Field(min_length=1, max_length=300)
    due_at: datetime | None = None
    submission: str = Field(default='', max_length=1000)
    requirements: str = Field(default='', max_length=4000)
    evidence: list[Evidence] = Field(default_factory=list)
    needs_confirmation: list[str] = Field(default_factory=list)
    is_update: bool = False

    @field_validator('course', 'submission', 'requirements', mode='before')
    @classmethod
    def optional_text(cls, value):
        return '' if value is None else value

    @field_validator('due_at')
    @classmethod
    def local_date(cls, value):
        return aware(value) if value else None


class Extraction(BaseModel):
    tasks: list[ExtractedTask] = Field(max_length=30)


class MaterialInput(BaseModel):
    name: str = Field(default='粘贴的通知', min_length=1, max_length=200)
    kind: Literal['text', 'image', 'pdf'] = 'text'
    text: str = Field(default='', max_length=60000)
    content_base64: str = Field(default='', max_length=14000000)
    mime: str = ''
    published_at: datetime | None = None


class ConfirmInput(BaseModel):
    task: ExtractedTask
    estimated_minutes: int = Field(ge=30, le=10080, multiple_of=30)
    target_id: str | None = None
    expected_version: int | None = None


class EditInput(ConfirmInput):
    completed: bool = False


class Interval(BaseModel):
    start: datetime
    end: datetime
    label: str = ''

    @model_validator(mode='after')
    def dates(self):
        self.start, self.end = aware(self.start), aware(self.end)
        if self.end <= self.start:
            raise ValueError('结束时间必须晚于开始时间')
        return self


class PlanInput(BaseModel):
    start: datetime
    available: list[Interval] = Field(max_length=100)
    blocked: list[Interval] = Field(default_factory=list, max_length=100)

    @field_validator('start')
    @classmethod
    def date(cls, value):
        return aware(value)

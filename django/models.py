"""
Django model for the D1 (staged/enforced) student_onboarding record.

Field constraints here are intentionally as strict as the BigQuery schema
in terraform/main.tf — this model is the Django-side source of truth that
the serializer in serializers.py validates against before a record is
ever allowed to reach D1.
"""

import uuid

from django.core.validators import RegexValidator
from django.db import models

PHONE_VALIDATOR = RegexValidator(
    regex=r"^\+[1-9]\d{7,14}$",
    message="Phone number must be in E.164 format, e.g. +14155552671. No local formats accepted.",
)


class StudentOnboarding(models.Model):
    """One enforced (D1) record. See dcyn_library.py for how the Y/N
    fields below are derived from raw D0 payload values — this model
    only ever stores the already-resolved DCYN values, never the raw
    free-text the guardian originally submitted.
    """

    class DCYNChoice(models.TextChoices):
        YES = "Y", "Yes"
        NO = "N", "No"

    record_id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)

    full_legal_name = models.CharField(max_length=120)
    date_of_birth = models.DateField()
    guardian_email = models.EmailField(max_length=254)
    guardian_phone = models.CharField(max_length=20, validators=[PHONE_VALIDATOR])
    region = models.CharField(
        max_length=8
    )  # matches the BigQuery RLS predicate's region column

    has_diagnosed_learning_difficulty = models.CharField(
        max_length=1, choices=DCYNChoice.choices
    )
    diagnosis_document_reference = models.CharField(
        max_length=64, null=True, blank=True
    )

    guardian_consent_given = models.CharField(max_length=1, choices=DCYNChoice.choices)
    requires_lsa_accommodation = models.CharField(
        max_length=1, choices=DCYNChoice.choices
    )
    prior_lsa_support_received = models.CharField(
        max_length=1, choices=DCYNChoice.choices
    )

    loaded_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "d1_student_onboarding"
        constraints = [
            # Mirrors the DCYN dependency rule enforced in the serializer —
            # belt-and-suspenders so a direct DB write can't bypass it either.
            models.CheckConstraint(
                check=(
                    models.Q(has_diagnosed_learning_difficulty="N")
                    | (
                        models.Q(has_diagnosed_learning_difficulty="Y")
                        & ~models.Q(diagnosis_document_reference="")
                        & models.Q(diagnosis_document_reference__isnull=False)
                    )
                ),
                name="diagnosis_reference_required_if_yes",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.record_id} ({self.region})"

"""
Task 3 — Schema Mapping and DCYN Validation

Deconstructs the incoming student-onboarding JSON payload into the
DCYN binary Yes/No library and produces the exact record shape the D1
BigQuery table (terraform/main.tf) expects.
"""

from __future__ import annotations

from datetime import date

from rest_framework import serializers

from .dcyn_library import DCYN, DCYNError

_ALLOWED_REGIONS = frozenset({"UAE", "KSA", "QAT", "KWT", "BHR", "OMN"})

_YES_STRINGS = frozenset({"yes", "y", "true"})
_NO_STRINGS = frozenset({"no", "n", "false"})


class StudentOnboardingSerializer(serializers.Serializer):
    """Validates and deconstructs one raw onboarding payload.

    All numeric/length limits below are explicit and exact, and are
    enforced at the DRF layer. The DCYN library resolves the derived
    Yes/No fields once validation passes.
    """

    full_legal_name = serializers.CharField(
        max_length=120,
        min_length=2,
        trim_whitespace=True,
        error_messages={
            "max_length": "full_legal_name must not exceed 120 characters.",
            "min_length": "full_legal_name must be at least 2 characters.",
        },
    )
    date_of_birth = serializers.DateField(
        input_formats=["%Y-%m-%d"],
        error_messages={
            "invalid": "date_of_birth must be an ISO-8601 date (YYYY-MM-DD)."
        },
    )
    guardian_email = serializers.EmailField(max_length=254)
    guardian_phone = serializers.RegexField(
        regex=r"^\+[1-9]\d{7,14}$",
        error_messages={
            "invalid": "guardian_phone must be E.164 format, e.g. +14155552671."
        },
    )
    region = serializers.ChoiceField(choices=sorted(_ALLOWED_REGIONS))

    # Raw payload sends free-text-ish values; the serializer resolves them
    # to strict booleans at the DRF layer, then to DCYN in validate().
    has_diagnosed_learning_difficulty = serializers.BooleanField()
    diagnosis_document_reference = serializers.CharField(
        max_length=64, required=False, allow_null=True, allow_blank=False
    )
    guardian_consent_given = serializers.BooleanField()
    requires_lsa_accommodation = serializers.BooleanField()
    prior_lsa_support_received = serializers.BooleanField()

    def validate_date_of_birth(self, value: date) -> date:
        today = date.today()
        age_years = (today - value).days // 365
        if age_years < 3 or age_years > 19:
            raise serializers.ValidationError(
                "date_of_birth implies an age outside the supported 3-19 year range. "
                "No exception path exists for out-of-range ages — escalate manually, "
                "outside this pipeline."
            )
        return value

    def validate(self, attrs: dict) -> dict:
        """Cross-field DCYN rules. Each raises with an exact, actionable
        reason if the record is fail-closed and must not be retried automatically.
        """
        try:
            consent = DCYN.from_bool(attrs["guardian_consent_given"])
            diagnosis = DCYN.from_bool(attrs["has_diagnosed_learning_difficulty"])
        except DCYNError as exc:
            raise serializers.ValidationError(str(exc)) from exc

        if consent == DCYN.NO:
            raise serializers.ValidationError(
                "guardian_consent_given resolves to No. This record is fail-closed: "
                "it will not be written to D1 and must not be retried automatically."
            )

        try:
            DCYN.require_dependency(
                trigger=diagnosis,
                dependent_value=attrs.get("diagnosis_document_reference"),
                field_name="diagnosis_document_reference",
            )
        except DCYNError as exc:
            raise serializers.ValidationError(str(exc)) from exc

        return attrs

    def to_dcyn_record(self, validated_data: dict) -> dict:
        """Produce the flat, D1-ready record. This is the only function
        downstream loaders should call — it is the single seam where raw
        booleans become the DCYN "Y"/"N" strings the BigQuery schema
        (terraform/main.tf) declares.
        """
        return {
            "full_legal_name": validated_data["full_legal_name"],
            "date_of_birth": validated_data["date_of_birth"].isoformat(),
            "guardian_email": validated_data["guardian_email"],
            "region": validated_data["region"],
            "has_diagnosed_learning_difficulty": DCYN.from_bool(
                validated_data["has_diagnosed_learning_difficulty"]
            ).value,
            "diagnosis_document_reference": validated_data.get(
                "diagnosis_document_reference"
            ),
            "guardian_consent_given": DCYN.from_bool(
                validated_data["guardian_consent_given"]
            ).value,
            "requires_lsa_accommodation": DCYN.from_bool(
                validated_data["requires_lsa_accommodation"]
            ).value,
            "prior_lsa_support_received": DCYN.from_bool(
                validated_data["prior_lsa_support_received"]
            ).value,
        }

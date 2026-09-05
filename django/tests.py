"""
Tests for Task 3. These are the "objective evidence" the brief asks for:
each failure path is a deliberate invalid payload, and every assertion
checks that the record is REJECTED, not merely flagged.
"""

from datetime import date, timedelta

from django.test import SimpleTestCase

from .serializers import StudentOnboardingSerializer


def _base_payload(**overrides):
    payload = {
        "full_legal_name": "Fatima Al Suwaidi",
        "date_of_birth": (date.today() - timedelta(days=365 * 9)).isoformat(),
        "guardian_email": "guardian@example.com",
        "guardian_phone": "+971501234567",
        "region": "UAE",
        "has_diagnosed_learning_difficulty": True,
        "diagnosis_document_reference": "DOC-2026-0042",
        "guardian_consent_given": True,
        "requires_lsa_accommodation": True,
        "prior_lsa_support_received": False,
    }
    payload.update(overrides)
    return payload


class StudentOnboardingSerializerTests(SimpleTestCase):
    def test_valid_payload_resolves_to_dcyn_record(self):
        serializer = StudentOnboardingSerializer(data=_base_payload())
        self.assertTrue(serializer.is_valid(), serializer.errors)
        record = serializer.to_dcyn_record(serializer.validated_data)
        self.assertEqual(record["has_diagnosed_learning_difficulty"], "Y")
        self.assertEqual(record["guardian_consent_given"], "Y")
        self.assertEqual(record["prior_lsa_support_received"], "N")

    def test_missing_consent_fails_closed(self):
        serializer = StudentOnboardingSerializer(
            data=_base_payload(guardian_consent_given=False)
        )
        self.assertFalse(serializer.is_valid())
        self.assertIn("non_field_errors", serializer.errors)

    def test_diagnosis_yes_without_reference_fails_closed(self):
        serializer = StudentOnboardingSerializer(
            data=_base_payload(diagnosis_document_reference=None)
        )
        self.assertFalse(serializer.is_valid())

    def test_malformed_phone_rejected(self):
        serializer = StudentOnboardingSerializer(
            data=_base_payload(guardian_phone="050-123-4567")  # local format, not E.164
        )
        self.assertFalse(serializer.is_valid())
        self.assertIn("guardian_phone", serializer.errors)

    def test_age_out_of_supported_range_rejected(self):
        serializer = StudentOnboardingSerializer(
            data=_base_payload(
                date_of_birth=(date.today() - timedelta(days=365 * 25)).isoformat()
            )
        )
        self.assertFalse(serializer.is_valid())
        self.assertIn("date_of_birth", serializer.errors)

    def test_unrecognized_region_rejected(self):
        serializer = StudentOnboardingSerializer(data=_base_payload(region="US"))
        self.assertFalse(serializer.is_valid())
        self.assertIn("region", serializer.errors)

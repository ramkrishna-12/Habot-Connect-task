"""
DCYN — Deconstructed Contextual Yes/No library
------------------------------------------------
Task 3 requires deconstructing an incoming JSON payload into a binary
Yes/No logic library "to entirely eliminate human judgment."""

from __future__ import annotations

from enum import Enum


class DCYNError(ValueError):
    """Raised when an input cannot be resolved to a Yes/No answer."""


class DCYN(str, Enum):
    YES = "Y"
    NO = "N"

    @classmethod
    def from_bool(cls, value: object) -> "DCYN":
        """Convert a strict Python bool to DCYN. Refuses truthy/falsy coercion.

        ``1``, ``"true"``, ``"yes"``, ``None`` and ``[]`` are all rejected
        """
        if not isinstance(value, bool):
            raise DCYNError(
                f"from_bool requires an actual bool, got {type(value).__name__!r} "
                f"({value!r}). No truthy/falsy coercion is permitted."
            )
        return cls.YES if value else cls.NO

    @classmethod
    def from_choice(
        cls,
        value: object,
        yes_values: frozenset[str],
        no_values: frozenset[str],
    ) -> "DCYN":
        """Convert a free-text choice field (e.g. "Yes"/"No"/"Y"/"N") to DCYN.

        yes_values and no_values must be disjoint, lower-cased sets
        supplied by the caller — this function does not guess synonyms.
        """
        if not isinstance(value, str):
            raise DCYNError(
                f"from_choice requires a string, got {type(value).__name__!r}."
            )
        normalized = value.strip().lower()
        if normalized in yes_values:
            return cls.YES
        if normalized in no_values:
            return cls.NO
        raise DCYNError(
            f"Value {value!r} does not match any recognized Yes/No choice. "
            f"Allowed YES: {sorted(yes_values)}. Allowed NO: {sorted(no_values)}. "
            "Unrecognized input fails closed rather than defaulting."
        )

    @classmethod
    def require_dependency(
        cls,
        trigger: "DCYN",
        dependent_value: object,
        field_name: str,
    ) -> None:
        """Enforce a DCYN-to-DCYN dependency rule, e.g.:

        has_diagnosed_learning_difficulty == YES  =>  diagnosis_document_reference must be present.
        """
        if trigger == cls.YES and not dependent_value:
            raise DCYNError(
                f"Dependency violation: trigger answered YES but required field "
                f"{field_name!r} is missing or blank."
            )

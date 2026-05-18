from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from app.settings import Settings


class AppStoreValidationError(Exception):
    pass


@dataclass(frozen=True)
class VerifiedAppleTransaction:
    transaction_id: str
    original_transaction_id: str | None
    product_id: str
    environment: str | None
    purchase_date: datetime | None
    expires_date: datetime | None
    revocation_date: datetime | None


class AppStoreTransactionValidator:
    def __init__(self, settings: Settings):
        self.settings = settings

    def verify_subscription_transaction(self, signed_transaction: str) -> VerifiedAppleTransaction:
        if not self.settings.app_store_root_certificates_dir:
            raise AppStoreValidationError(
                "App Store root certificates are not configured on the backend."
            )

        try:
            from appstoreserverlibrary.models.Environment import Environment
            from appstoreserverlibrary.signed_data_verifier import (
                SignedDataVerifier,
                VerificationException,
            )
        except ImportError as exc:
            raise AppStoreValidationError(
                "Apple App Store Server Library is not installed on the backend."
            ) from exc

        root_certificates = self._load_root_certificates(
            self.settings.app_store_root_certificates_dir
        )
        if not root_certificates:
            raise AppStoreValidationError(
                "No Apple root certificates were found for App Store transaction validation."
            )

        environment = (
            Environment.PRODUCTION
            if self.settings.app_store_environment == "production"
            else Environment.SANDBOX
        )
        try:
            verifier = SignedDataVerifier(
                root_certificates,
                self.settings.app_store_enable_online_checks,
                environment,
                self.settings.app_store_bundle_id,
                self.settings.app_store_app_apple_id,
            )
            payload = verifier.verify_and_decode_signed_transaction(signed_transaction)
        except (ValueError, VerificationException) as exc:
            raise AppStoreValidationError(f"Apple transaction verification failed: {exc}") from exc

        if payload.productId != self.settings.apple_subscription_product_id:
            raise AppStoreValidationError("Apple transaction product id does not match plus.")
        if not payload.transactionId:
            raise AppStoreValidationError("Apple transaction is missing a transaction id.")

        expires_date = self._date_from_ms(payload.expiresDate)
        revocation_date = self._date_from_ms(payload.revocationDate)
        if revocation_date is not None:
            raise AppStoreValidationError("Apple transaction has been revoked.")
        if expires_date is None or expires_date <= datetime.now(UTC):
            raise AppStoreValidationError("Apple subscription transaction is expired.")

        return VerifiedAppleTransaction(
            transaction_id=payload.transactionId,
            original_transaction_id=payload.originalTransactionId,
            product_id=payload.productId,
            environment=payload.environment.value if payload.environment else None,
            purchase_date=self._date_from_ms(payload.purchaseDate),
            expires_date=expires_date,
            revocation_date=revocation_date,
        )

    @staticmethod
    def _load_root_certificates(directory: Path) -> list[bytes]:
        if not directory.exists() or not directory.is_dir():
            return []
        certificates: list[bytes] = []
        for path in sorted(directory.iterdir()):
            if path.suffix.lower() in {".cer", ".der"}:
                certificates.append(path.read_bytes())
        return certificates

    @staticmethod
    def _date_from_ms(value: int | None) -> datetime | None:
        if value is None:
            return None
        return datetime.fromtimestamp(value / 1000, tz=UTC)

"""Sync HTTP contract; synchronous handlers keep disk I/O off the event loop."""
from fastapi import APIRouter, HTTPException, Request

import apple_auth
from sync_store import OperationConflict, StaleRevision, SyncRecoveryError, SyncStore, Upload

router = APIRouter()


def _user(request):
    user = apple_auth.current_user_from_request(request.headers.get("Authorization"))
    if not user:
        raise HTTPException(status_code=401, detail="unauthorized")
    return user


@router.get("/sync/v2")
def download(request: Request):
    user = _user(request)
    try:
        return SyncStore(apple_auth.SYNC_DIR).read(user["user_id"])
    except SyncRecoveryError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@router.post("/sync/v2")
def upload(request: Request, body: Upload):
    user = _user(request)
    try:
        return SyncStore(apple_auth.SYNC_DIR).write(user["user_id"], body)
    except (StaleRevision, OperationConflict) as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except SyncRecoveryError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

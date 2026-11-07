from app.model_registry import register_models
from app.workers.runner import run_forever

register_models()
run_forever()

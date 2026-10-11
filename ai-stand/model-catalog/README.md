# Каталог и профили моделей

catalog.lock.json фиксирует vendor refs, версии, quantization, размеры и SHA-256 артефактов. prepare.py скачивает или проверяет модели; повторно используемые partial downloads проверяются перед продолжением. Веса и caches хранятся только в persistent storage установки.

selection.py связывает активные модели и параметры inference с конкретным runtime pin и GFX. Профиль установки задаёт accelerator, hardware/GFX, модель, quantization, контекст, embedding dimensions и другие параметры запуска. Добавление новой лаборатории требует отдельного профиля, а не изменения generic defaults.

Команды подготовки и проверки каталога: prepare.py --role chat|embedding --root PATH и --verify-only. Production model apply выполняется отдельной установочной стадией после готовности backend.

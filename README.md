# AI automation workspace

Репозиторий содержит самостоятельные модули автоматизации. Подробная
документация и инструкции находятся в README каждого модуля.

| Модуль | Назначение |
| --- | --- |
| [`software`](software/README.md) | Резолвинг, проверка и установка Windows-программ по YAML-манифесту. |
| [`ansible-setup`](ansible-setup/README.md) | Ansible-роль для provisioning системных Linux-аккаунтов по inventory. |
| [`ai-stand`](ai-stand/README.md) | Локальная AI-платформа на Docker Swarm: модели, веб-интерфейсы, SSO, MCP и шлюзы. |
| [`mcp-readonly-common`](mcp-readonly-common/README.md) | Общая .NET-библиотека для внутренних read-only MCP-адаптеров. |
| [`jira-readonly-mcp`](jira-readonly-mcp/README.md) | Read-only MCP к Jira Data Center через native REST API. |
| [`confluence-readonly-mcp`](confluence-readonly-mcp/README.md) | Read-only MCP к Confluence Data Center через native REST API. |
| [`imap-readonly-mcp`](imap-readonly-mcp/README.md) | Read-only MCP к одной IMAP-учётной записи. |

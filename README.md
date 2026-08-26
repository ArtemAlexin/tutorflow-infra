# Tutorflow Kubernetes infrastructure

Репозиторий содержит Helm-чарты для одного Kubernetes-кластера с двумя namespace:

- `tutorflow-test` — одиночные PostgreSQL, MongoDB и Redis без управления операторами;
- `tutorflow-prod` — PostgreSQL, MongoDB и общий Redis под управлением операторов.

Terraform и managed database services не используются.

## Структура

```text
helm/
  database-operators/      # PostgreSQL, Redis и MongoDB Community operators
  tutorflow-postgresql/    # PostgreSQL: operator CR для prod или StatefulSet для test
  tutorflow-mongodb/       # MongoDB: operator CR для prod или StatefulSet для test
  tutorflow-redis/         # Redis: operator CR для prod или StatefulSet для test
  temporal/
  novu/
  zitadel/

environments/
  test/
  prod/
  local/
```

Novu запускается четырьмя компонентами: API, Worker, WebSocket и Dashboard. Он использует базу `novu-db` в общей MongoDB и общий Redis. В production Novu подключается к Service `tutorflow-redis-master`, который Redis Operator поддерживает на текущем writable master; отдельный Redis для Novu не создаётся.

PostgreSQL содержит:

- `tutorflow` для Tutorflow;
- `temporal` и `temporal_visibility` для Temporal;
- `zitadel` для ZITADEL.

## Подготовка values

```powershell
$stand = "prod"

Copy-Item environments\$stand\postgresql.values.example.yaml environments\$stand\postgresql.values.yaml
Copy-Item environments\$stand\mongodb.values.example.yaml environments\$stand\mongodb.values.yaml
Copy-Item environments\$stand\redis.values.example.yaml environments\$stand\redis.values.yaml
Copy-Item environments\$stand\temporal.values.example.yaml environments\$stand\temporal.values.yaml
Copy-Item environments\$stand\novu.values.example.yaml environments\$stand\novu.values.yaml
Copy-Item environments\$stand\zitadel.values.example.yaml environments\$stand\zitadel.values.yaml
```

Рабочие `*.values.yaml` игнорируются Git. До установки замените все `replace-with-*`, домены и email.

Секреты Novu генерируются один раз:

```powershell
openssl rand -hex 32 # JWT_SECRET
openssl rand -hex 16 # STORE_ENCRYPTION_KEY: ровно 32 символа
openssl rand -hex 32 # NOVU_SECRET_KEY
```

Не меняйте `STORE_ENCRYPTION_KEY` после настройки providers: им зашифрованы их credentials. Для паролей MongoDB и Redis также удобно использовать `openssl rand -hex 32`.

## Операторы для prod

Операторы устанавливаются в `tutorflow-prod` и наблюдают только его. Отдельного namespace `database-operators` нет: в инфраструктуре остаются только `tutorflow-test` и `tutorflow-prod`.

```powershell
$namespace = "tutorflow-prod"
kubectl create namespace $namespace --dry-run=client -o yaml | kubectl apply -f -

helm dependency build helm\database-operators

helm upgrade --install database-operators helm\database-operators `
  --namespace $namespace `
  --wait --timeout 15m
```

Оператор Redis получает namespace-scoped RBAC только в `tutorflow-prod`. В `tutorflow-test` операторы не устанавливаются, ничего не наблюдают и не создают.

## Test без операторов

Каждая БД выпускается отдельным Helm release. В test это одиночные StatefulSet PostgreSQL, MongoDB и Redis. Имена Service и Secret совпадают с prod, поэтому прикладные чарты одинаковы для обоих стендов.

```powershell
$namespace = "tutorflow-test"

helm upgrade --install tutorflow-postgresql helm\tutorflow-postgresql `
  --namespace $namespace `
  --create-namespace `
  --values environments\test\postgresql.values.yaml `
  --wait --timeout 20m

helm upgrade --install tutorflow-mongodb helm\tutorflow-mongodb `
  --namespace $namespace `
  --values environments\test\mongodb.values.yaml `
  --wait --timeout 20m

helm upgrade --install tutorflow-redis helm\tutorflow-redis `
  --namespace $namespace `
  --values environments\test\redis.values.yaml `
  --wait --timeout 20m
```

Standalone PostgreSQL и MongoDB создают пользователей и базы только при первом запуске с пустыми PVC. Изменение паролей в values после инициализации не меняет пароли внутри уже созданных баз.

## Prod с операторами

```powershell
$namespace = "tutorflow-prod"

helm upgrade --install tutorflow-postgresql helm\tutorflow-postgresql `
  --namespace $namespace `
  --create-namespace `
  --values environments\prod\postgresql.values.yaml `
  --wait --timeout 30m

helm upgrade --install tutorflow-mongodb helm\tutorflow-mongodb `
  --namespace $namespace `
  --values environments\prod\mongodb.values.yaml `
  --wait --timeout 30m

helm upgrade --install tutorflow-redis helm\tutorflow-redis `
  --namespace $namespace `
  --values environments\prod\redis.values.yaml `
  --wait --timeout 30m
```

Проверка:

```powershell
kubectl -n $namespace get postgresql,mongodbcommunity
kubectl -n $namespace get redisreplication,redissentinel
kubectl -n $namespace get pods,pvc
```

## Приложения

```powershell
helm upgrade --install temporal helm\temporal `
  --namespace $namespace `
  --values environments\$stand\temporal.values.yaml `
  --wait --timeout 15m

helm upgrade --install novu helm\novu `
  --namespace $namespace `
  --values environments\$stand\novu.values.yaml `
  --wait --timeout 20m

helm upgrade --install zitadel helm\zitadel `
  --namespace $namespace `
  --values environments\$stand\zitadel.values.yaml `
  --wait --timeout 15m
```

Для Novu нужно опубликовать через Ingress три Service:

- `novu-dashboard:4000` по адресу из `config.dashboardUrl`;
- `novu-api:3000` по адресу из `config.apiRootUrl`;
- `novu-ws:3002` по адресу из `config.websocketUrl` с поддержкой WebSocket upgrade.

После входа в Dashboard настройте email/SMS/push providers и создайте API key для Tutorflow. Social login в self-hosted Novu не поддерживается.

## Переход с Notifuse

Notifuse и Novu используют разные модели данных, автоматической миграции workspaces и templates нет. После проверки Novu прежний release можно удалить:

```powershell
helm uninstall notifuse --namespace $namespace
```

Удаление release не удаляет старые `notifuse_system` и workspace databases из существующего PostgreSQL. Их очистку выполняйте отдельно только после backup и проверки, что Notifuse больше не нужен.

## Отказоустойчивость и backup

Операторы обеспечивают failover pod, но не заменяют резервные копии. Для production нужны PostgreSQL WAL/PITR, MongoDB backup и резервное копирование PVC общего Redis. В test Redis использует AOF, чтобы не терять очередь Novu при рестарте.

На двух worker-нодах нельзя построить полноценный трёхузловой кворум без риска потери доступности при обслуживании; topology и resource budget нужно согласовать с фактическим количеством нод.

## Проверка charts

```powershell
helm dependency build helm\database-operators
helm lint helm\database-operators
helm lint helm\tutorflow-postgresql --values environments\test\postgresql.values.example.yaml
helm lint helm\tutorflow-postgresql --values environments\prod\postgresql.values.example.yaml
helm lint helm\tutorflow-mongodb --values environments\test\mongodb.values.example.yaml
helm lint helm\tutorflow-mongodb --values environments\prod\mongodb.values.example.yaml
helm lint helm\tutorflow-redis --values environments\test\redis.values.example.yaml
helm lint helm\tutorflow-redis --values environments\prod\redis.values.example.yaml
helm lint helm\novu --values environments\test\novu.values.example.yaml
helm lint helm\novu --values environments\prod\novu.values.example.yaml
```

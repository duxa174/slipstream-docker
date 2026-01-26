IMAGE ?= slipstream-ss
CONTAINER ?= slipstream-ss
HOST_DNS_PORT ?= 53
DATA_VOLUME ?= slipstream-data
COMPOSE ?= docker compose
DOCKER_BUILDKIT ?= 1

.PHONY: build run run-noninteractive logs ssurl compose-up compose-up-noninteractive compose-down

build:
	DOCKER_BUILDKIT=$(DOCKER_BUILDKIT) docker build -t $(IMAGE) .

run:
	docker run -it --rm --name $(CONTAINER) \
		-p $(HOST_DNS_PORT):53/udp \
		-v $(DATA_VOLUME):/data \
		$(IMAGE)

run-noninteractive:
	@if [ ! -f .env ]; then echo "Missing .env (copy .env.example and edit)."; exit 1; fi
	docker run -d --name $(CONTAINER) \
		-p $(HOST_DNS_PORT):53/udp \
		-v $(DATA_VOLUME):/data \
		--env-file .env \
		$(IMAGE)

logs:
	docker logs -f $(CONTAINER)

ssurl:
	docker exec $(CONTAINER) cat /data/config/client-config.txt

compose-up:
	$(COMPOSE) --profile interactive up

compose-up-noninteractive:
	$(COMPOSE) --profile non-interactive up -d

compose-down:
	$(COMPOSE) down

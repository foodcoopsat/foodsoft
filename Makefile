.PHONY: image-dev image-prod image-prod-dev

IMAGE_NAME=mortbauer/foodsoft
IMAGE_TAG:=latest
BUILD_ARGS:= --build-arg REVISION="$(shell git rev-parse HEAD)" --build-arg BUILDTIME="$(shell date --rfc-3339=seconds)"

image-dev:
	docker buildx build --tag ${IMAGE_NAME}-rubocop:${IMAGE_TAG} --progress=plain --target=dev .

image-prod:
	docker buildx build --builder default --tag ${IMAGE_NAME}:${IMAGE_TAG} --progress=plain --target=app ${BUILD_ARGS} .

image-prod-push:
	docker buildx build  --builder default --tag ${IMAGE_NAME}:${IMAGE_TAG} --progress=plain --target=app ${BUILD_ARGS} --push .

image-prod-dev:
	docker buildx build --tag ${IMAGE_NAME}:${IMAGE_TAG} --progress=plain --target=app ${BUILD_ARGS} .

rubocop:
	docker run --rm -it -v ${PWD}:/work:ro --workdir /work foodsoft-rubocop bash

cleanup-routes:
	git checkout plugins/*/config/routes.rb
	git checkout config/routes.rb

dev-certs:
	mkdir -p dev_data/certs 2>>/dev/null || true
	mkcert -cert-file dev_data/certs/app.local.at.pem -key-file dev_data/certs/app.local.at-key.pem '*.local.at' '*.app.local.at'

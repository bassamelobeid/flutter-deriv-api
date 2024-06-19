# README

### Running locally

```
docker build -t pricing-service-web:latest .
docker run --rm -it -p 4000:8000 -v ${PWD}:/docs pricing-service-web
```

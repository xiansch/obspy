FROM edos/wheezy32:latest

MAINTAINER Lion Krischer

# Can fail on occasion.
RUN apt-get update && apt-get upgrade || true
RUN apt-get -y install python-numpy python-scipy python-matplotlib python-sqlalchemy python-lxml python-mock python-mpltoolkits.basemap python-mpltoolkits.basemap-data python-pip ttf-bitstream-vera python-decorator python-requests
RUN pip install flake8 future
RUN echo "backend: agg" > /etc/matplotlibrc

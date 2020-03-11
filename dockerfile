# Dockerfile to develop rte-rrtmg (https://github.com/RobertPincus/rte-rrtmgp/)
#
# git clone https://github.com/RobertPincus/rte-rrtmgp/
# docker build . -t observingclouds/rte-rrtmgp
# docker run -it --rm -v /absolute/path/to/git/rte-rrtmgp:/rte-rtmgp observingclouds/rte-rrtmgp
# e.g. docker run -it --rm -v $PWD:/rte-rrtmgp  observingclouds/rte-rrtmgp
# cd /rte-rrtmgp/build/
# make
# cd /rte-rrtmgp/examples/rfmip-clear-sky/
# make
# python stage_files.py
# python run-rfmip-examples.py
# python compare-to-reference.py
# cd /rte-rrtmgp/examples/all-sky/
# make
# python run-allsky-example.py
# python compare-to-reference.py

FROM debian:latest

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
ENV PATH /opt/conda/bin:$PATH

RUN apt-get update --fix-missing && \
    apt-get install -y wget git build-essential nano && \
    apt-get install -y gcc gfortran && \
    apt-get install -y libnetcdf-dev libnetcdff-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN wget --quiet https://repo.anaconda.com/miniconda/Miniconda3-4.5.11-Linux-x86_64.sh -O ~/miniconda.sh && \
    /bin/bash ~/miniconda.sh -b -p /opt/conda && \
    rm ~/miniconda.sh && \
    /opt/conda/bin/conda clean -tipsy && \
    ln -s /opt/conda/etc/profile.d/conda.sh /etc/profile.d/conda.sh && \
    echo ". /opt/conda/etc/profile.d/conda.sh" >> ~/.bashrc && \
    echo "conda activate base" >> ~/.bashrc

RUN conda install netCDF4 xarray dask

ENV NFHOME /usr
ENV FCFLAGS -ffree-line-length-none
ENV RRTMGP_ROOT /rte-rrtmgp
ENV RRTMGP_DIR  /rte-rrtmgp/build

ENV TINI_VERSION v0.16.1
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /usr/bin/tini
RUN chmod +x /usr/bin/tini

WORKDIR /rte-rrtmgp

ENTRYPOINT [ "/usr/bin/tini", "--" ]
CMD [ "/bin/bash" ]

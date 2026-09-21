ARG UPSTREAM_IMAGE=kingbase_v009r001c010b0004_single_x86:v1
ARG PYTHON_RUNTIME_IMAGE=openeuler/openeuler:21.03@sha256:b7d5dad69632004e129cd06abae0fc734a6be9321739c72a36e4a9c457d56618

FROM ${PYTHON_RUNTIME_IMAGE} AS python-runtime

# The upstream 21.03 mirror has moved to archives.  Install Python in an
# otherwise disposable stage because the vendor image's dnf is not runnable.
RUN sed -i 's#http://repo.openeuler.org#http://archives.openeuler.openatom.cn#g' \
      /etc/yum.repos.d/openEuler.repo \
    && dnf install -y python3 \
    && dnf clean all

FROM ${UPSTREAM_IMAGE}

USER root

ENV KINGBASE_HOME=/home/kingbase/install/kingbase \
    PATH=/home/kingbase/install/kingbase/bin:${PATH}

# The vendor image exposes Python 3.8 but omits its standard library.  Carry
# the matching openEuler 21.03 runtime rather than depending on a runtime
# package installation when the container starts.
COPY --from=python-runtime /usr/bin/python3 /usr/bin/python3
COPY --from=python-runtime /usr/bin/python3.8 /usr/bin/python3.8
COPY --from=python-runtime /usr/lib64/libpython3.8.so.1.0 /usr/lib64/libpython3.8.so.1.0
COPY --from=python-runtime /usr/lib64/libpython3.so /usr/lib64/libpython3.so
COPY --from=python-runtime /usr/lib64/python3.8 /usr/lib64/python3.8

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY kingbase-ha-manager.py /usr/local/bin/kingbase-ha-manager.py
COPY kingbase-role-probe.sh /usr/local/bin/kingbase-role-probe.sh
COPY kingbase-switchover.sh /usr/local/bin/kingbase-switchover.sh
COPY kingbase-exporter.py /usr/local/bin/kingbase-exporter.py
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/kingbase-ha-manager.py \
    /usr/local/bin/kingbase-role-probe.sh /usr/local/bin/kingbase-switchover.sh \
    /usr/local/bin/kingbase-exporter.py

EXPOSE 54321 8008 9187
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["kingbase"]

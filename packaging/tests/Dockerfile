FROM pocket-connect-test-base:preview
RUN useradd --create-home --uid 1234 tester
COPY dist/*.deb /tmp/packages/
RUN dpkg -i /tmp/packages/*.deb
COPY packaging/tests/smoke_linux.py /opt/smoke_linux.py
USER tester
ENV HOME=/home/tester POCKET_ISOLATED_TEST=1
CMD ["python3", "/opt/smoke_linux.py"]

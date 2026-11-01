import runpy
import sys
from pathlib import Path


if __name__ == '__main__':
    directory = Path(__file__).resolve().parents[1] / '.github' / 'ci'
    sys.path.insert(0, str(directory))
    runpy.run_path(str(directory / Path(__file__).name), run_name='__main__')

import numpy as np
import os
from testutil import translate_and_import

def test_conv1d():
    # we need parentheses around Vec after ':' to parse correctly
    ks_str = """
(def conv1d (Vec (Vec Float)) ((kernels : (Vec (Vec (Vec Float))))
                               (image : (Vec (Vec Float))))
  (let ((k (size kernels))
        (kernels_elt (index 0 kernels))
        (kn (size (index 0 kernels_elt)))
        (l  (size image))
        (n  (size (index 0 image))))
    (build k (lam (ki : Integer)
      (build n (lam (ni : Integer)
        (sumbuild kn (lam (kni : Integer)
          (sumbuild l  (lam (li  : Integer)
            (let ((knc (div kn 2))
                  (noi (sub (add ni knc) kni))
                  (outside_image (or (lt noi 0) (gte noi n)))
                  (image_noi
                  (if outside_image 0.0 (index noi (index li image)))))
              (mul image_noi (index kni (index li (index ki kernels))))
        )))))))))))"""
    py_out = translate_and_import(ks_str, "common")
    image = np.random.normal(0, 1, (1, 100))
    kernel = np.array(
      [[[-0.5, 0, 0.5]],
      [[0.333, 0.333, 0.333]]]
    )
    assert kernel.shape == (2, 1, 3)
    expected_output = np.vstack((
      np.convolve(image[0], kernel[0,0], 'same'),
      np.convolve(image[0], kernel[1,0], 'same')))
    output = py_out.conv1d(kernel, image)
    assert np.allclose(expected_output, output)
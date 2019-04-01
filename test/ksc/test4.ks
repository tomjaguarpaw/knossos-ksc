(def test_tuple Integer ((x : Tuple (Vec Float) (Vec (Vec Float)) Integer))
    (+ 1 (if (< 2 3) 4 5)))


(def g Float ((w : Tuple Float Integer))
    (get$1$2 w))
    
(def g2 Float ((wishart : Tuple Float Integer))
    (let ((wishart_gamma (get$1$2 wishart))
         (f (* 2.2 wishart_gamma))
         )
      f))

(def main Integer ()
    (let (w (tuple 3.3 4))
        (pr (g w)
            (rev$g w 1.0)
            )))